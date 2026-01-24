require 'io/console'

class ViPager
  # content_list: [{type: ..., thread_info: ...}, ...]
  # HistoryManagerへの依存を排除
  def initialize(content_list)
    @content_list = content_list
    @lines = []
    @line_info = [] 
    @input_buffer = "" 
    prepare_content
  end

  def prepare_content
    @content_list.each do |item|
      case item[:type]
      when :header
        th = item[:thread_info]
        add_line(" " * 60, th, 0, :bg_blue) 
        add_line("【#{th[:title]}】", th, 0, :bold)
        add_line(" URL: #{th[:url]} (既読: #{th[:last_read]})", th, 0)
        add_line("=" * 60, th, 0)
      when :unread_marker
        add_line("▼▼▼ ここから未読 ▼▼▼", item[:thread_info], 0, :red)
      when :system_msg
        add_line("  #{item[:message]}", item[:thread_info], 0, :dim)
      when :post
        post = item[:data]
        th = item[:thread_info]
        header = "#{post[:num]} : #{post[:name]} [#{post[:date]}]"
        add_line(header, th, post[:num], :bold)
        post[:message].each_line do |l|
          add_line("  " + l.chomp, th, post[:num])
        end
        add_line("-" * 60, th, post[:num], :dim)
      when :separator
        add_line("", nil, 0)
        add_line("      ( 次のスレッドへ続く )      ", nil, 0, :dim)
        add_line("", nil, 0)
      when :error
        add_line("!!! #{item[:message]} !!!", item[:thread_info], 0, :red)
      end
    end
    add_line("(End of Stream)", nil, 0, :dim)
  end

  def add_line(text, thread_info, res_num, style = nil)
    @lines << { text: text, style: style }
    @line_info << { thread: thread_info, res: res_num }
  end

  # 戻り値: 最後に見ていた位置情報 { thread: ..., res: ... } または nil
  def start
    rows, cols = IO.console.winsize
    current_line = 0
    max_scroll = [@lines.size - rows, 0].max

    loop do
      max_scroll = [@lines.size - rows, 0].max 
      render(current_line, rows, cols)
      input = STDIN.getch
      
      # 現在表示中の最下行のスレッド情報を特定
      visible_bottom = [current_line + rows - 1, @lines.size - 1].min
      current_context = nil
      scan_idx = visible_bottom
      while scan_idx >= 0
        info = @line_info[scan_idx]
        if info && info[:thread] && info[:res] > 0
          current_context = info
          break
        end
        scan_idx -= 1
      end

      if input =~ /[0-9]/; next; end

      case input
      when 'q'
        # 終了時に現在のコンテキスト（どこまで読んだか）を返す
        return current_context 
      when 'j', "\r", "\n" then current_line += 1 if current_line < max_scroll
      when 'k'             then current_line -= 1 if current_line > 0
      when 'f', ' '        then current_line += (rows - 1); current_line = max_scroll if current_line > max_scroll
      when "\u0004"        then current_line += (rows / 2); current_line = max_scroll if current_line > max_scroll
      when 'b'             then current_line -= (rows - 1); current_line = 0 if current_line < 0
      when "\u0015"        then current_line -= (rows / 2); current_line = 0 if current_line < 0
      when 'g'             then current_line = 0
      when 'G'             then current_line = max_scroll
      when "\e"
        extra = STDIN.getch
        if extra == "["
          arrow = STDIN.getch
          case arrow
          when "A" then current_line -= 1 if current_line > 0
          when "B" then current_line += 1 if current_line < max_scroll
          end
        end
      end
    end
  end

  def render(offset, rows, cols)
    print "\e[H\e[2J" 
    view_lines = @lines[offset, rows] || []
    view_lines.each do |line_data|
      text = line_data[:text]
      display_text = text.length > cols ? text[0, cols-3] + "..." : text
      case line_data[:style]
      when :bold    then puts "\e[1m#{display_text}\e[0m"
      when :red     then puts "\e[31m#{display_text}\e[0m"
      when :dim     then puts "\e[2m#{display_text}\e[0m"
      when :bg_blue then puts "\e[44;1m#{display_text}\e[0m"
      else               puts display_text
      end
    end
  end
end
