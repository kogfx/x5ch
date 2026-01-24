require 'net/http'
require 'uri'
require 'json'
require_relative '../config'

class DiscordManager
  attr_reader :token, :channel_id

  def initialize
    @token = Config::DISCORD_BOT_TOKEN
    @channel_id = Config::DISCORD_CHANNEL_ID
  end

  # --- 設定が有効かチェックするメソッド ---
  def enabled?
    # トークンがない、空、または初期値のままなら無効とみなす
    return false if @token.nil? || @token.empty? || @token.include?("YOUR_BOT_TOKEN")
    # チャンネルIDがない場合も無効
    return false if @channel_id.nil? || @channel_id.empty?
    
    true
  end
  # ----------------------------------------

  def create_thread(title)
    return nil unless enabled?

    uri = URI.parse("https://discord.com/api/v10/channels/#{@channel_id}/threads")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri.path)
    request["Authorization"] = "Bot #{@token}"
    request["Content-Type"] = "application/json"
    
    # スレッド名は100文字制限があるのでカットする
    safe_title = title.length > 95 ? title[0, 95] + "..." : title

    request.body = {
      name: safe_title,
      type: 11, # GUILD_PUBLIC_THREAD
      auto_archive_duration: 1440 # 24時間
    }.to_json

    begin
      response = http.request(request)
      if response.code == "201"
        data = JSON.parse(response.body)
        return data["id"]
      else
        return nil
      end
    rescue
      return nil
    end
  end

  def send_message(thread_id, post)
    return unless enabled? && thread_id

    # 1. 本文の整形 (h抜きURL補完)
    # (?<!h) は「直前にhがない場合」という否定後読みです。
    # これにより、既に https:// になっているものは無視し、ttps:// だけを https:// に変換します。
    body = post[:body].to_s.gsub(/(?<!h)(ttps?:\/\/)/, 'h\1')

    # 2. メッセージ全体の構築
    # ヘッダー: 番号 : 名前 : 日付 ID:xxx
    header = "**#{post[:num]}** : #{post[:name]} : #{post[:date]} ID:#{post[:id]}"
    full_content = "#{header}\n#{body}"

    # 3. 文字数チェックと送信
    if full_content.length <= 2000
      # 2000文字以下ならそのまま送信
      post_content(thread_id, full_content)
    else
      # 2000文字超えなら分割して送信
      # 安全マージンをとって1900文字単位で分割
      parts = full_content.scan(/.{1,1900}/m)
      
      parts.each_with_index do |part, index|
        # 続きがある場合は末尾に注釈を入れる
        suffix = (index < parts.size - 1) ? "\n(続く...)" : ""
        
        post_content(thread_id, part + suffix)
        
        # 連投制限に引っかからないよう少し待つ
        sleep 0.5
      end
    end
  end

  private

  def post_content(thread_id, content)
    uri = URI.parse("https://discord.com/api/v10/channels/#{thread_id}/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri.path)
    request["Authorization"] = "Bot #{@token}"
    request["Content-Type"] = "application/json"
    
    request.body = {
      content: content
    }.to_json

    begin
      response = http.request(request)
      # レートリミット(429)の場合の簡易対応
      if response.code == "429"
        retry_after = 1
        begin
          json = JSON.parse(response.body)
          retry_after = json["retry_after"] || 1
        rescue
        end
        sleep retry_after
        post_content(thread_id, content)
      elsif response.code.to_i >= 400
        raise "Discord API Error: #{response.code} #{response.body}"
      end
    rescue => e
      raise e
    end
  end
end
