#! /usr/bin/env ruby
# x5ch - Terminal 5ch Browser & Discord Archiver
# Copyright (c) 2026 kogfx (@kogfx)
# Released under the BSD 3-Clause License.

require_relative 'lib/five_ch_browser'
require_relative 'config'

def main
  lock_file = File.open(Config::LOCK_FILE, File::RDWR | File::CREAT)
  unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
    exit
  end

  File.write(Config::PID_FILE, Process.pid.to_s)

  puts "[#{Time.now.strftime('%H:%M:%S')}] === 自動巡回 Start ==="
  
  browser = FiveChBrowser.new
  browser.transfer_worker.cron_mode = true

  # ★重要: 前回の残骸があっても、勝手に転送を開始しないように止める！
  browser.transfer_worker.suspend

  updates_list = []

  begin
    # ==========================================
    # Phase 1: 未読チェック
    # ==========================================
    puts "[#{Time.now.strftime('%H:%M:%S')}] Check: 履歴を確認中..."
    
    browser.history.get_recent_threads.each do |history_item|
      break if $stop_requested
      
      title_disp = history_item[:title].to_s.gsub("\n", "")
      if title_disp.length > 40
        title_disp = title_disp[0, 38] + ".."
      end
      
      print "   Checking: #{title_disp.ljust(42)} "
      STDOUT.flush

      begin
        posts = browser.get_thread_data(history_item)
        if posts
          last_read = history_item[:last_read] || 0
          new_count = posts.count { |p| p[:num] > last_read }
          
          if new_count > 0
            puts "=> (+#{new_count}) \e[31mFound!\e[0m"
            updates_list << history_item
          else
            puts "=> (0)"
          end
        else
          puts "=> (Error: No Data)"
        end
        sleep 1.0
      rescue => e
        puts "=> (Error: #{e.message})"
      end
    end

    # ==========================================
    # Phase 2: 転送処理
    # ==========================================
    puts ""
    
    # 新しく見つかったものをキューに追加
    if updates_list.any?
      updates_list.each do |item|
        browser.transfer_worker.enqueue(item)
      end
    end

    # キューに残っている総数を確認
    total_queue = browser.transfer_worker.remaining_threads
    
    if total_queue > 0
      puts "[#{Time.now.strftime('%H:%M:%S')}] Queue: 合計 #{total_queue}件のスレッドを転送します..."
      
      # ★重要: ここで初めて転送を許可する
      browser.transfer_worker.resume
      
      # wait_until_done を使うとシグナルに反応できないため、
      # 自前でループして $stop_requested を監視する
      while browser.transfer_worker.busy?
        if $stop_requested
          puts "\nStopping transfer..."
          break
        end
        sleep 1.0
      end
    else
      puts "[#{Time.now.strftime('%H:%M:%S')}] No updates (Queue empty)."
    end

  rescue Interrupt
    puts "\nInterrupted."
    browser.transfer_worker.kill
  ensure
    File.delete(Config::PID_FILE) if File.exist?(Config::PID_FILE)
    lock_file.close
    puts "[#{Time.now.strftime('%H:%M:%S')}] === Finish ==="
  end
end

Signal.trap(:TERM) do
  $stop_requested = true
  puts "\nSignal received. Stopping..."
end

if __FILE__ == $0
  main
end
