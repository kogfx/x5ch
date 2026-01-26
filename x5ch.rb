#! /usr/bin/env ruby
# x5ch - Terminal 5ch Browser & Discord Archiver
# Copyright (c) 2026 kogfx (@kogfx)
# Released under the BSD 3-Clause License.

require_relative 'lib/five_ch_browser'

# --- 1. キュー管理画面 ---
def manage_queue(browser)
  loop do
    queue_items = browser.transfer_worker.get_queue_list
    
    print "\e[H\e[2J"
    puts "=== 転送待機列の管理 ==="
    puts " 現在の待機数: #{queue_items.size}"
    puts " 削除したいタスクの番号を入力してください。"
    puts " (b: 戻る)"
    puts "------------------------------------------------"
    
    if queue_items.empty?
      puts " (待機中のタスクはありません)"
    else
      queue_items.each_with_index do |item, i|
        puts "[#{i}] #{item[:title]}"
      end
    end
    
    print "\nCommand > "
    
    char = nil
    begin
      STDIN.raw { |io| char = io.getc }
    rescue
      char = STDIN.getch
    end

    if char == 'b' || char == 'q'
      break
    else
      print char
      rest = gets
      input = (char + rest).chomp
      
      if input =~ /^\d+$/
        idx = input.to_i
        deleted = browser.transfer_worker.delete_at(idx)
        if deleted
          puts "\n\e[31m削除しました: #{deleted[:title]}\e[0m"
          sleep 1.0
        end
      end
    end
  end
end

# --- 2. 履歴管理画面 (メインメニュー用) ---
def manage_history(browser)
  loop do
    history_items = browser.history.get_recent_threads
    
    print "\e[H\e[2J"
    puts "=== 閲覧履歴の管理 (削除) ==="
    puts " 削除したい履歴の番号を入力してください。"
    puts " (b: 戻る)"
    puts "------------------------------------------------"
    
    if history_items.empty?
      puts " (履歴はありません)"
    else
      history_items.each_with_index do |item, i|
        puts "[#{i}] #{item[:title]} (Read: #{item[:last_read]})"
      end
    end
    
    print "\nDelete No > "
    
    char = nil
    begin
      STDIN.raw { |io| char = io.getc }
    rescue
      char = STDIN.getch
    end

    if char == 'b' || char == 'q'
      break
    else
      print char
      rest = gets
      input = (char + rest).chomp
      
      if input =~ /^\d+$/
        idx = input.to_i
        if idx >= 0 && idx < history_items.size
          target = history_items[idx]
          if browser.history.delete_thread(target[:board_url], target[:dat_file])
            puts "\n\e[31m履歴を削除しました: #{target[:title]}\e[0m"
            sleep 0.8
          end
        else
          puts "\n無効な番号です"
          sleep 0.5
        end
      end
    end
  end
end

# --- 3. アイテム選択・UI制御 ---
def select_item(items, title, start_page = 0, mode = :category, browser = nil)
  return [:back, 0] if items.empty?
  page_size = 20
  current_page = start_page
  original_items = items
  filtered_items = items
  filter_keyword = nil
  input_buffer = ""
  
  needs_full_redraw = true

  loop do
    total_pages = (filtered_items.size/page_size.to_f).ceil
    current_page = 0 if current_page >= total_pages
    current_page = total_pages - 1 if current_page < 0
    
    start_idx = current_page * page_size
    view_items = filtered_items[start_idx, page_size] || []

    display_title = title
    display_title += " (検索: #{filter_keyword})" if filter_keyword
    q_status = browser.transfer_worker.status_string
    header_str = "--- #{display_title} (#{current_page + 1}/#{[total_pages, 1].max})#{q_status} ---"

    valid_range = "#{start_idx}-#{start_idx + [view_items.size - 1, 0].max}"
    search_label = ",s"
    search_label = ",s(全スレ検索)" if mode == :category
    search_label = ",s(絞り込み)" if mode == :board || mode == :thread
    
    prompt_keys = "[#{valid_range},Enter,p,b#{search_label},h,q,t"
    prompt_keys += ",r,m,H" if mode == :thread 
    prompt_keys += ",H" if mode == :category   
    prompt_keys += "] > "

    if needs_full_redraw
      print "\e[H\e[2J" 
      puts header_str
      
      view_items.each_with_index do |item, i|
        display_name = item[:title]
        info = ""
        prefix_mark = " "

        if item[:is_recent]
          display_name = "\e[1;36m#{item[:title]}\e[0m"

        elsif mode == :thread
          # ... (既存のスレッド表示ロジック) ...
          mark = " "
          mark = "\e[31m+\e[0m" if item[:has_new]
          if (item[:last_read] && item[:last_read] > 0) || item[:is_queued]
             display_name = "\e[36m#{item[:title]}\e[0m" 
             prefix_mark = "\e[36m✔\e[0m" unless item[:has_new]
             mark = "\e[32m.\e[0m" if !item[:has_new]
          end
          if item[:ikioi] && item[:ikioi] > 0
            info = "#{mark} (#{item[:count]}/#{item[:ikioi].to_i})"
          elsif item[:count]
            info = "#{mark} (#{item[:count]})"
          elsif item[:last_read]
            info = "(Read: #{item[:last_read]})"
          end

        elsif mode == :board
          # ... (既存の板表示ロジック) ...
          if browser && browser.history.has_history_in_board?(item[:url])
            display_name = "\e[36m#{item[:title]} (履歴あり)\e[0m"
            prefix_mark = "\e[36m*\e[0m"
          end

        elsif mode == :category
          # ... (既存のカテゴリ表示ロジック) ...
          if item[:boards] && browser && browser.history.has_history_in_category?(item[:boards])
            display_name = "\e[36m#{item[:title]} (履歴あり)\e[0m"
            prefix_mark = "\e[36m*\e[0m"
          end
        end

        puts "[#{start_idx + i}] #{prefix_mark}#{info} #{display_name}"
      end
      
      print prompt_keys
      print input_buffer
      needs_full_redraw = false
    else
      # 部分更新
      print "\e[H#{header_str}\e[K"
      prompt_row = view_items.size + 2
      print "\e[#{prompt_row};1H"
      print prompt_keys
      print input_buffer
    end

    char = nil
    begin
      STDIN.raw do |io|
        if IO.select([io], nil, nil, 1.0)
          char = io.getc
        end
      end
    rescue
      char = STDIN.getch
    end

    next unless char

    if char == "\u0003"
      # 値を返さず、例外を投げることで main の rescue Interrupt ブロックへ直行させる
      raise Interrupt
    end

    if char =~ /[0-9]/
      input_buffer << char
      next 
    end

    if char == "\r" || char == "\n"
      if input_buffer.empty?
        current_page += 1
      else
        idx = input_buffer.to_i
        input_buffer = ""
        return [filtered_items[idx], current_page] if idx >= 0 && idx < filtered_items.size
      end
      needs_full_redraw = true 
      next
    end

    if char == "\u007F" || char == "\b"
      input_buffer.chop!
      next
    end

    input_buffer = "" 

    case char
    when 'q' 
      return [:quit, current_page] 
    when 'b' 
      return [:back, current_page]
    when 'r'
      needs_full_redraw = true
      return [:reload, current_page] if mode == :board || mode == :thread
    when 't'
      manage_queue(browser)
      needs_full_redraw = true
      next
    when 'H'
      if mode == :category
        manage_history(browser)
        needs_full_redraw = true
        next
      elsif mode == :thread
        print "\n履歴を削除する番号を入力 > "
        idx_str = gets
        if idx_str && idx_str.chomp =~ /^\d+$/
          idx = idx_str.to_i
          if idx >= 0 && idx < filtered_items.size
             item = filtered_items[idx]
             if item[:last_read] && item[:last_read] > 0
               if browser.history.delete_thread(item[:board_url], item[:dat_file])
                 item[:last_read] = 0
                 item[:is_queued] = false # フラグも消す
                 puts "\n\e[31m>> 履歴を削除しました: #{item[:title]}\e[0m"
               else
                 puts "\n削除に失敗しました"
               end
               sleep 1.0
             else
               puts "\n履歴がない(未読の)スレッドです"
               sleep 0.5
             end
          end
        end
        needs_full_redraw = true
      end
    when 'm'
      if mode == :thread
        unless browser.discord.enabled?
          puts "\n\e[31m[Error] Token未設定\e[0m"; sleep 1; needs_full_redraw = true; next
        end
        print "\n転送する番号を入力 > "
        idx_str = gets
        if idx_str && idx_str.chomp =~ /^\d+$/
          idx = idx_str.to_i
          if idx >= 0 && idx < filtered_items.size
             item = filtered_items[idx]
             
             # 1. キューに追加
             browser.transfer_worker.enqueue(item)
             
             # 2. 履歴に登録
             browser.history.add_new_thread(item[:title], item[:board_url], item[:dat_file])
             
             # 3. ★修正箇所: メモリ上のデータを更新し、強制的に色をつけるフラグを立てる
             item[:last_read] = 0
             item[:is_queued] = true 

             puts ">> キューに追加: #{item[:title]}"
             sleep 0.5
          end
        end
        needs_full_redraw = true 
      end
    when 'h'
      print "\e[H\e[2J"
      puts "=== キー操作ヘルプ ==="
      puts " 数字  : 決定 / Enter : 次ページ"
      puts " m     : [NEW] 転送キューに追加"
      puts " t     : [NEW] 転送キューの管理"
      if mode == :category
        puts " H     : [NEW] 閲覧履歴の管理(削除)"
      elsif mode == :thread
        puts " H     : [NEW] 選択したスレッドの履歴を削除"
      end
      puts " s     : 検索 / r : リロード / q : 終了 / b : 戻る"
      puts " Ctrl+C: 待機列を保存して終了"
      STDIN.getch
      needs_full_redraw = true
      next
    when 's'
      print "\n検索キーワード > "
      keyword = gets
      keyword = keyword ? keyword.chomp : ""
      if keyword.empty?
        needs_full_redraw = true
        next
      end
      
      if mode == :category && browser
        results = browser.search_global(keyword)
        if results.empty?
          puts "見つかりませんでした。"; STDIN.getch
        else
          last_p = 0
          loop do
            res_thread, last_p = select_item(results, "全板検索結果: #{keyword}", last_p, :thread, browser)
            break if res_thread == :quit || res_thread == :back
            browser.show_thread(res_thread)
          end
        end
        needs_full_redraw = true
      else
        filter_keyword = keyword
        filtered_items = original_items.select { |i| i[:title].include?(keyword) }
        current_page = 0
        if filtered_items.empty?
          puts "該当なし"; STDIN.getch
          filtered_items = original_items
          filter_keyword = nil
        end
        needs_full_redraw = true
      end
    when 'p' 
      current_page -= 1
      needs_full_redraw = true
    end
  end
end

# --- 4. メインルーチン ---
def main
  lock_file = File.open(Config::LOCK_FILE, File::RDWR | File::CREAT)

  # ロックチェック
  unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
    puts "\e[33m[Notice] バックグラウンドで転送プロセス(Cron)が稼働中です。\e[0m"
    if File.exist?(Config::PID_FILE)
      pid = File.read(Config::PID_FILE).to_i
      if pid > 0
        print "プロセス(PID: #{pid})を停止し、処理を引き継ぎます..."
        
        # 1. 優しく終了要請 (TERM)
        begin
          Process.kill(:TERM, pid)
        rescue Errno::ESRCH
          # プロセスが既にいない場合
        end

        # 2. 最大5秒待つ
        5.times do
          sleep 1.0
          begin
            Process.getpgid(pid) # プロセス生存確認
            print "."
          rescue Errno::ESRCH
            break # いなくなった
          end
        end

        # 3. まだ生きてたら強制終了 (KILL)
        begin
          Process.getpgid(pid)
          print " 応答がないため強制終了します(KILL)..."
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH
        end
      end
    end
    
    print " ロック取得..."
    lock_file.flock(File::LOCK_EX) 
    puts " 完了。\n\e[32m>> 処理を引き継いで起動します。\e[0m"
    sleep 1.0
  end

  File.write(Config::PID_FILE, Process.pid.to_s)

  browser = FiveChBrowser.new
  last_cat_page = 0
  
  begin
    loop do
      cats = browser.get_menu
      recent_entry = { title: "★ 最近読んだスレッド", is_recent: true }
      menu_items = [recent_entry] + cats

      selected_item, last_cat_page = select_item(menu_items, "メインメニュー", last_cat_page, :category, browser)
      
      break if selected_item == :quit
      next if selected_item == :back

      if selected_item[:is_recent]
        recent_threads = browser.history.get_recent_threads
        if recent_threads.empty?
          puts "履歴がありません"; sleep 1; next
        end
        browser.show_recent_stream(recent_threads)
        next
      end

      cat = selected_item
      last_board_page = 0
      loop do
        board, last_board_page = select_item(cat[:boards], cat[:title], last_board_page, :board, browser)
        break if board == :quit || board == :back
        next if board == :reload
        
        last_thread_page = 0
        loop do
          puts "スレッド一覧取得中..."
          threads = browser.get_threads(board, false) 
          thread, last_thread_page = select_item(threads, board[:title], last_thread_page, :thread, browser)
          
          break if thread == :quit || thread == :back
          
          if thread == :reload
            puts "最新情報を取得中..."
            threads = browser.get_threads(board, true) 
            next
          end
          
          browser.show_thread(thread)
        end
      end
    end
    
    browser.transfer_worker.wait_until_done

  rescue Interrupt
    puts "\n\e[31m保存して終了します。\e[0m"
    browser.transfer_worker.kill
    exit
  ensure
    File.delete(Config::PID_FILE) if File.exist?(Config::PID_FILE)
    lock_file.close
  end

  print "\e[H\e[2J"
end

if __FILE__ == $0
  main
end
