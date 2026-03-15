require 'json'
require 'monitor'
require_relative '../config'

class HistoryManager
  include MonitorMixin

  private

 def normalize_url(url)
    url.to_s
       .sub(/^https?:\/\//, '')      # http(s):// 削除
       .sub(/^www\./, '')            # www. 削除
       .sub(/\/$/, '')               # 末尾スラッシュ削除
       .gsub('2ch.net', '5ch.io')   # ドメイン統一
       .gsub('5ch.net', '5ch.io')   # ドメイン統一
  end

  public

  def initialize
    super()
    @data = {}
    load_history
  end

  def load_history
    synchronize do
      if File.exist?(Config::HISTORY_FILE)
        begin
          json = File.read(Config::HISTORY_FILE)
          @data = JSON.parse(json)
        rescue
          @data = {}
        end
      else
        @data = {}
      end
    end
  end

  def save_history
    synchronize do
      File.write(Config::HISTORY_FILE, JSON.pretty_generate(@data))
      return true
    end
  rescue
    return false
  end

  # URLを正規化して一意なキーを作成する
  def generate_key(board_url, dat_file)
    "#{normalize_url(board_url)}::#{dat_file}"
  end

  def get_last_read(board_url, dat_file)
    synchronize do
      key = generate_key(board_url, dat_file)
      entry = @data[key]
      if entry.is_a?(Hash); entry["res"] || 0
      else; 0; end
    end
  end
  
  def get_discord_thread_id(board_url, dat_file)
    synchronize do
      key = generate_key(board_url, dat_file)
      entry = @data[key]
      return nil unless entry.is_a?(Hash)
      entry["discord_thread_id"]
    end
  end

  def exists?(board_url, dat_file)
    synchronize do
      key = generate_key(board_url, dat_file)
      @data.key?(key)
    end
  end

  def has_history_in_board?(board_url)
    synchronize do
      target = normalize_url(board_url)
      
      @data.values.any? do |entry|
        next false unless entry.is_a?(Hash)
        # 保存データのURLも同じメソッドで正規化して比較
        normalize_url(entry["board_url"]) == target
      end
    end
  end

  def has_history_in_category?(boards_list)
    return false unless boards_list.is_a?(Array)
    boards_list.any? { |b| has_history_in_board?(b[:url]) }
  end

  def add_new_thread(title, board_url, dat_file)
    synchronize do
      key = generate_key(board_url, dat_file)
      return if @data.key?(key)

      @data[key] = {
        "res" => 0,
        "title" => title,
        "board_url" => board_url,
        "dat_file" => dat_file,
        "timestamp" => Time.now.to_i,
        "discord_thread_id" => nil
      }
      save_history
    end
  end

  def delete_thread(board_url, dat_file)
    synchronize do
      key = generate_key(board_url, dat_file)
      if @data.delete(key)
        save_history
        return true
      end
      false
    end
  end

  def update_history(thread_info, res_num, discord_thread_id = nil)
    synchronize do
      b_url = thread_info[:board_url] || thread_info["board_url"]
      d_file = thread_info[:dat_file] || thread_info["dat_file"]
      title = thread_info[:title] || thread_info["title"]

      key = generate_key(b_url, d_file)
      
      entry = @data[key]
      entry = {} unless entry.is_a?(Hash)
      
      current_res = entry["res"] || 0
      new_res = res_num > current_res ? res_num : current_res
      
      current_discord_id = entry["discord_thread_id"]
      new_discord_id = discord_thread_id || current_discord_id

      @data[key] = {
        "res" => new_res,
        "title" => title,
        "board_url" => b_url,
        "dat_file" => d_file,
        "timestamp" => Time.now.to_i,
        "discord_thread_id" => new_discord_id
      }
      save_history
    end
  end

  def get_recent_threads
    synchronize do
      threads = []
      @data.each do |key, val|
        next unless val.is_a?(Hash) && val["title"]
        threads << {
          title: val["title"],
          board_url: val["board_url"],
          dat_file: val["dat_file"],
          count: 0, ikioi: 0,
          timestamp: val["timestamp"] || 0,
          last_read: val["res"],
          has_new: false, is_history_item: true
        }
      end
      threads.sort_by { |t| -t[:timestamp] }
    end
  end
end
