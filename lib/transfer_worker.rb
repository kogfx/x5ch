require 'thread'
require 'json'
require 'monitor'
require 'net/http'
require_relative '../config'

class TransferWorker
  include MonitorMixin

  attr_reader :current_title, :last_error
  attr_accessor :cron_mode

  def initialize(browser)
    super()
    @browser = browser
    @queue = [] 
    @working = false
    @current_title = nil
    @current_task = nil
    @last_error = nil
    
    @total_messages = 0
    @current_message_index = 0
    
    @shutdown_requested = false
    @cv = new_cond
    
    @cron_mode = false
    @suspended = false # ★追加: 一時停止フラグ
    
    load_queue
    @monitor_thread = start_thread
  end

  # ★追加: 処理を一時停止する
  def suspend
    synchronize do
      @suspended = true
    end
  end

  # ★追加: 処理を再開する
  def resume
    synchronize do
      @suspended = false
      @cv.broadcast # 待機中のスレッドを起こす
    end
  end

  def save_queue
    synchronize do
      File.write(Config::QUEUE_FILE, JSON.pretty_generate(@queue))
    end
  rescue => e
    # エラー時は無視
  end

  def load_queue
    synchronize do
      if File.exist?(Config::QUEUE_FILE)
        begin
          json = File.read(Config::QUEUE_FILE)
          data = JSON.parse(json, symbolize_names: true)
          if data.is_a?(Array)
            @queue = data
            unless @cron_mode
              puts ">> 前回の転送待ちリストを復元しました (#{@queue.size}件)"
              sleep 1.0
            end
          end
        rescue
          @queue = []
        end
      end
    end
  end

  def enqueue(thread_info)
    synchronize do
      @last_error = nil
      task = {
        title: thread_info[:title],
        board_url: thread_info[:board_url],
        dat_file: thread_info[:dat_file]
      }
      @queue.push(task)
      save_queue 
      @cv.signal
    end
  end

  def delete_at(index)
    synchronize do
      if index >= 0 && index < @queue.size
        removed = @queue.delete_at(index)
        save_queue
        return removed
      end
    end
    nil
  end

  def get_queue_list
    synchronize do
      @queue.dup
    end
  end

  def busy?
    synchronize { !@queue.empty? || @working }
  end

  def remaining_threads
    synchronize { @queue.size }
  end

  def kill
    synchronize do
      @shutdown_requested = true
      
      if @working && @current_task
        @queue.unshift(@current_task)
      end

      save_queue 
      @cv.broadcast
    end
  end

  def status_string
    if @last_error
      return " \e[41m[#{@last_error}]\e[0m"
    end
    
    is_busy, rem, w, title, cur, tot = synchronize { 
      [busy?, @queue.size, @working, @current_title, @current_message_index, @total_messages] 
    }

    return "" unless is_busy

    title_info = title ? "#{title[0, 8]}..." : "準備中"
    progress = (w && tot > 0) ? "(#{cur}/#{tot})" : ""
    queue_info = rem > 0 ? " [待機スレ:#{rem}]" : ""
    
    " \e[33m[転送中:#{title_info}#{progress}#{queue_info}]\e[0m"
  end

  def wait_until_done
    return unless busy?
    
    if @cron_mode
      while busy?
        sleep 1.0
      end
    else
      puts "\n\e[33m転送処理が残っています。すべて完了するまで待機します...\e[0m"
      while busy?
        print "\r#{status_string}   "
        sleep 1.0
      end
      puts "\n完了しました。"
    end
    save_queue 
  end

  private

  def start_thread
    Thread.new do
      loop do
        task = nil
        
        synchronize do
          # ★修正: キューが空、または「一時停止中(@suspended)」なら待機する
          while (@queue.empty? || @suspended) && !@shutdown_requested
            @cv.wait
          end

          break if @shutdown_requested
          
          # 停止解除された瞬間にキューが空の可能性もあるので再チェック
          if !@queue.empty?
            task = @queue.shift
            @current_task = task 
            save_queue
          end
        end

        break if @shutdown_requested && task.nil?
        
        if task
          @working = true
          @current_title = task[:title]
          @total_messages = 0
          @current_message_index = 0
          
          begin
            process_mirror(task)
          rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, SocketError => e
            msg = "Network Error! Retry later..."
            @last_error = msg
            puts "\n[Error] #{msg}" if @cron_mode
            sleep 30
            synchronize do
              @queue.push(task)
              save_queue
            end
          rescue => e
            # Discord API Error 4 などもここで捕捉
            @last_error = e.message[0, 20]
            # 429 Too Many Requests などの可能性もあるため、少し待って戻す
            if e.message.include?("Discord API Error")
               puts "\n[Error] #{e.message} (Waiting 10s...)" if @cron_mode
               sleep 10
               synchronize do
                 @queue.push(task)
                 save_queue
               end
            else
               puts "\n[Error] #{@last_error}" if @cron_mode
            end
          end
          
          synchronize do
            @current_task = nil
            @current_title = nil
            @working = false
          end
        end
      end
    end
  end

  def process_mirror(thread_info)
    posts = @browser.get_thread_data(thread_info)
    return unless posts

    discord = @browser.discord
    history = @browser.history

    discord_thread_id = history.get_discord_thread_id(thread_info[:board_url], thread_info[:dat_file])
    
    unless discord_thread_id
      discord_thread_id = discord.create_thread(thread_info[:title])
      return unless discord_thread_id
      history.update_history(thread_info, 0, discord_thread_id)
    end

    last_read = history.get_last_read(thread_info[:board_url], thread_info[:dat_file])
    new_posts = posts.select { |p| p[:num] > last_read }

    return if new_posts.empty?

    @total_messages = new_posts.size

    if @cron_mode
      print "[転送] #{thread_info[:title][0, 15]}... (#{@total_messages}件): "
      STDOUT.flush
    end

    new_posts.each_with_index do |post, idx|
      break if @shutdown_requested
      @current_message_index = idx + 1
      discord.send_message(discord_thread_id, post)
      history.update_history(thread_info, post[:num], discord_thread_id)
      
      if @cron_mode
        print "."
        STDOUT.flush
      end
      sleep 1.0 
    end

    if @cron_mode
      puts " OK"
    end
  end
end
