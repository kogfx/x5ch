require 'net/http'
require 'uri'
require 'zlib'
require 'stringio'
require 'json'
require_relative '../config'
require_relative 'encoding_helper'
require_relative 'history_manager'
require_relative 'discord_manager' 
require_relative 'transfer_worker'
require_relative 'vi_pager'

class FiveChBrowser
  MENU_URL_JSON = "https://menu.5ch.net/bbsmenu.json"
  MENU_URL_HTML = "https://menu.5ch.net/bbsmenu.html"

  attr_reader :history, :discord, :transfer_worker

  def initialize
    @menu_cache = nil
    @history = HistoryManager.new
    @thread_list_cache = {}
    @discord = DiscordManager.new
    @transfer_worker = TransferWorker.new(self)
  end

  def fetch_with_redirect(url_str, limit = 5)
    raise "リダイレクト回数が上限に達しました" if limit == 0
    uri = URI.parse(url_str)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true if uri.scheme == 'https'
    http.open_timeout = 30
    http.read_timeout = 30
    request = Net::HTTP::Get.new(uri.request_uri)
    request['User-Agent'] = Config::USER_AGENT
    request['Accept-Encoding'] = 'gzip' 
    request['Connection'] = 'close'
    
    begin
      response = http.request(request)
    rescue => e
      raise "通信エラー: #{e.message}"
    end
    
    case response
    when Net::HTTPSuccess
      body = case response['content-encoding']
             when 'gzip' then Zlib::GzipReader.new(StringIO.new(response.body)).read
             else response.body
             end
      return [body, url_str]
    when Net::HTTPRedirection
      location = response['location']
      new_url = URI.join(url_str, location).to_s
      return fetch_with_redirect(new_url, limit - 1)
    else
      raise "HTTP Error: #{response.code} #{response.message}"
    end
  end

  def get_menu
    return @menu_cache if @menu_cache
    categories = []
    
    # 1. JSON試行
    puts "メニューを取得中(JSON)..."
    begin
      body, _ = fetch_with_redirect(MENU_URL_JSON)
      data = JSON.parse(body)
      if data["menu_list"].is_a?(Array)
        data["menu_list"].each do |cat|
          next unless cat["bbs"].is_a?(Array)
          boards = []
          cat["bbs"].each do |bbs|
            next unless bbs["url"]
            url = bbs["url"].gsub(/^http:/, "https:")
            url += "/" unless url.end_with?("/")
            boards << { title: bbs["name"], url: url }
          end
          categories << { title: cat["category_name"], boards: boards } unless boards.empty?
        end
        if categories.any?
          @menu_cache = categories
          return categories
        end
      end
    rescue
    end

    # 2. HTML試行
    puts "メニューを取得中(HTML): #{MENU_URL_HTML} ..."
    begin
      body, _ = fetch_with_redirect(MENU_URL_HTML)
      html = EncodingHelper.to_utf8(body)
      current_category = nil
      current_boards = []
      html.scan(/(?:<B>([^<]+)<\/B>)|(?:<A HREF=["']?([^ >"']+)["']?[^>]*>([^<]+)<\/A>)/i).each do |match|
        if match[0]
          categories << { title: current_category, boards: current_boards } if current_category && !current_boards.empty?
          current_category = match[0].strip
          current_boards = []
        elsif match[1]
          url = match[1]
          next unless url.include?("5ch.net") || url.include?("2ch.net")
          url = url.sub("2ch.net", "5ch.net").gsub(/^http:/, "https:")
          url += "/" unless url.end_with?("/")
          current_boards << { title: match[2].strip, url: url } if current_category
        end
      end
      categories << { title: current_category, boards: current_boards } if current_category && !current_boards.empty?
      
      if categories.any?
        @menu_cache = categories
        return categories
      end
    rescue
    end

    # 取得失敗時は空配列
    []
  end

  def get_threads(board_item, force_reload = false)
    url = board_item[:url]
    if !force_reload && @thread_list_cache[url]
      cache_data = @thread_list_cache[url]
      if Time.now - cache_data[:time] < Config::CACHE_EXPIRATION
        return cache_data[:data]
      end
    end

    subject_url = url + "subject.txt"
    begin
      data_binary, final_url = fetch_with_redirect(subject_url)
      board_item[:url] = final_url.sub(/subject\.txt$/, "") if final_url != subject_url
      data = EncodingHelper.to_utf8(data_binary)
    rescue => e
      return @thread_list_cache[url] ? @thread_list_cache[url][:data] : []
    end

    threads = []
    now = Time.now.to_i
    data.each_line do |line|
      if line =~ /^(\d+\.dat)<>(.*?)\((\d+)\)\s*$/
        dat_file = $1; title = $2.strip; count = $3.to_i
        ikioi = count / (([now - dat_file.to_i, 1].max) / 86400.0)
        last_read = @history.get_last_read(board_item[:url], dat_file)
        has_new = count > last_read
        threads << { 
          dat_file: dat_file, title: title, count: count, ikioi: ikioi, 
          board_url: board_item[:url], last_read: last_read, has_new: has_new
        }
      end
    end
    threads.sort_by! { |t| -t[:ikioi] }
    @thread_list_cache[url] = { data: threads, time: Time.now }
    threads
  end

  def search_global(keyword)
    puts "全板から「#{keyword}」を検索中(ff5ch)..."
    encoded_kw = URI.encode_www_form_component(keyword)
    url = "https://ff5ch.syoboi.jp/?q=#{encoded_kw}"
    begin
      body, _ = fetch_with_redirect(url)
      html = body.force_encoding('UTF-8').scrub
      results = []
      html.scan(/<a\s+[^>]*href="(https?:\/\/[^\.]+\.5ch\.net\/test\/read\.cgi\/[^\/]+\/\d+\/?)"[^>]*>(.+?)<\/a>/i).each do |match|
        full_url = match[0]; raw_title = match[1]
        if full_url =~ /https?:\/\/([^\.]+)\.5ch\.net\/test\/read\.cgi\/([^\/]+)\/(\d+)\/?/
          server = $1; board_name = $2; dat_file = $3
          title = raw_title.gsub(/<[^>]+>/, "").strip
          count = 0; count = $2.to_i if title =~ /^(.*)\((\d+)\)$/
          title = $1.strip if title =~ /^(.*)\((\d+)\)$/
          board_url = "https://#{server}.5ch.net/#{board_name}/"
          dat_filename = "#{dat_file}.dat"
          last_read = @history.get_last_read(board_url, dat_filename)
          has_new = count > last_read
          results << {
            title: title, count: count, ikioi: 0, 
            board_url: board_url, dat_file: dat_filename,
            url: "https://#{server}.5ch.net/test/read.cgi/#{board_name}/#{dat_file}/",
            last_read: last_read, has_new: has_new
          }
        end
      end
      return results
    rescue => e
      puts "検索エラー: #{e.message}"; sleep 2; return []
    end
  end

  def parse_posts(html)
    posts = []
    chunks = html.split(/<div\s+[^>]*class=["'][^"']*clear post[^"']*["'][^>]*>/)
    chunks.shift 
    chunks.each do |chunk|
      res_num = $1.to_i if chunk =~ /<span\s+class="postid">(\d+)<\/span>/
      next unless res_num
      name = $1.gsub(/<[^>]+>/, "").strip if chunk =~ /<span\s+class="postusername">(.+?)<\/span>/m
      date = $1.strip if chunk =~ /<span\s+class="date">(.+?)<\/span>/
      uid = $1.strip if chunk =~ /<span\s+class="uid">(.+?)<\/span>/
      date += " " + uid.to_s
      message = $1 if chunk =~ /<div\s+class="post-content">(.*?)<\/div>/m
      message ||= $1.sub(/<\/div>\s*\z/, "") if chunk =~ /<div\s+class="post-content">(.*)/m
      
      # クリーニング処理
      raw_msg = (message || "").gsub("<br>", "\n").gsub(/<[^>]+>/, " ").gsub("&gt;", ">").gsub("&lt;", "<").gsub("&amp;", "&").strip
      
      # ttp -> http 補完
      clean_message = raw_msg.gsub(/(^|[^h])(tps?:\/\/)/, '\1h\2')

      posts << { num: res_num, name: name || "名無し", date: date, message: clean_message }
    end
    posts
  end

  # 次スレ検出ロジック
  def detect_and_add_next_thread(posts, current_thread)
    candidates = posts.select { |p| p[:num] >= 900 }
    return if candidates.empty?

    return unless current_thread[:board_url] =~ %r{https?://([^/]+)/([^/]+)/}
    server = $1
    board = $2
    
    regex = %r{https?://#{Regexp.escape(server)}/test/read\.cgi/#{Regexp.escape(board)}/(\d+)/?}

    candidates.each do |post|
      post[:message].scan(regex).each do |match|
        dat_file = "#{match[0]}.dat"
        next if @history.exists?(current_thread[:board_url], dat_file)
        next if dat_file == current_thread[:dat_file]

        title = fetch_thread_title(current_thread[:board_url], match[0])
        if title
          @history.add_new_thread(title, current_thread[:board_url], dat_file)
        end
      end
    end
  end

  def fetch_thread_title(board_url, dat_key)
    uri = URI.parse(board_url)
    board_name = uri.path.split('/').reject(&:empty?).last
    read_url = "#{uri.scheme}://#{uri.host}/test/read.cgi/#{board_name}/#{dat_key}/"
    
    begin
      body, _ = fetch_with_redirect(read_url)
      html = EncodingHelper.to_utf8(body)
      if html =~ /<title>(.*?)<\/title>/i
        full_title = $1.strip
        return full_title.sub(/\s*[-|]\s*5ch\.net.*/i, "").strip
      end
    rescue
    end
    nil
  end

  def get_thread_data(thread_info)
    uri = URI.parse(thread_info[:board_url])
    board_name = uri.path.split('/').reject(&:empty?).last
    read_url = "#{uri.scheme}://#{uri.host}/test/read.cgi/#{board_name}/#{thread_info[:dat_file].to_i}/"
    begin
      body, final_url = fetch_with_redirect(read_url)
      return nil if body.include?("dat落ち")
      html = EncodingHelper.to_utf8(body)
      posts = parse_posts(html)
      thread_info[:url] = final_url
      
      # 次スレ検出
      detect_and_add_next_thread(posts, thread_info)

      return posts
    rescue; return nil; end
  end

  def show_thread(thread_info)
    # 1. 最新の既読位置を再取得
    saved_last_read = @history.get_last_read(thread_info[:board_url], thread_info[:dat_file])
    thread_info[:last_read] = saved_last_read if saved_last_read > 0
    last_read = thread_info[:last_read] || 0

    puts "スレッド取得中..."
    posts = get_thread_data(thread_info)
    
    if posts.nil? || posts.empty?
      puts "取得失敗またはdat落ち"; gets; return
    end
    thread_info[:count] = posts.size 

    # --- 表示データの構築 (全件渡す方式に変更) ---
    content = []
    content << {type: :header, thread_info: thread_info}

    marker_inserted = false

    posts.each do |p|
      # まだマーカーを入れておらず、かつ、このレス番号が既読を超えている場合
      if !marker_inserted && p[:num] > last_read
        # ここにマーカーを挿入
        content << {type: :unread_marker, thread_info: thread_info}
        marker_inserted = true
      end
      
      # レス本体は常に全て追加する（ここが重要）
      content << {type: :post, data: p, thread_info: thread_info}
    end

    # もし最後までマーカーが入らなかった（＝新着なし、または全部既読）場合
    unless marker_inserted
      # 末尾にマーカーを入れておくと、ViPagerが自動で一番下を表示してくれる
      content << {type: :unread_marker, thread_info: thread_info}
      content << {type: :system_msg, message: "(新着なし - 最終レスまで既読です)", thread_info: thread_info}
    end
    # -------------------------------------------
    
    pager = ViPager.new(content)
    result = pager.start
    
    if result && result[:res] > 0
      @history.update_history(thread_info, result[:res])
      
      thread_info[:last_read] = result[:res]
      if thread_info[:last_read] >= thread_info[:count]
        thread_info[:has_new] = false
        # スレッド一覧の表示更新のため、キューフラグなどは必要に応じて操作
      end

      puts "\n履歴を更新しました: #{result[:res]}"
      sleep 0.5
    end
  end

  def show_recent_stream(threads)
    content_list = []
    threads.each_with_index do |th, idx|
      print "\e[2K\r(#{idx+1}/#{threads.size}) 取得中: #{th[:title]}"
      posts = get_thread_data(th)
      unless posts
        content_list << { type: :error, message: "取得失敗: #{th[:title]}", thread_info: th }
        next
      end
      th[:count] = posts.size
      last_read = th[:last_read]
      content_list << { type: :header, thread_info: th }
      new_posts = posts.select { |p| p[:num] > last_read }

      if new_posts.empty?
        if last_read == 0
           content_list << { type: :unread_marker, thread_info: th }
           posts.each { |p| content_list << { type: :post, data: p, thread_info: th } }
        else
           content_list << { type: :system_msg, message: "(新着なし)", thread_info: th }
        end
      else
        if last_read > 0; content_list << { type: :unread_marker, thread_info: th }; end
        new_posts.each { |post| content_list << { type: :post, data: post, thread_info: th } }
      end
      content_list << { type: :separator, thread_info: th }
    end
    if content_list.empty?
      puts "\n表示できる内容がありません"; sleep 1; return
    end
    
    pager = ViPager.new(content_list)
    result = pager.start
    if result && result[:thread] && result[:res] > 0
      @history.update_history(result[:thread], result[:res])
      puts "\n履歴を更新しました: #{result[:thread][:title]} (#{result[:res]})"
      sleep 0.5
    end
  end
end
