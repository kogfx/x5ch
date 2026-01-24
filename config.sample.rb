# config.rb
module Config
  # --- Discord設定 ---
  DISCORD_BOT_TOKEN = "YOUR_BOT_TOKEN_HERE"
  DISCORD_CHANNEL_ID = "YOUR_CHANNEL_ID_HERE"

  # --- アプリ設定 ---
  HISTORY_FILE = File.join(Dir.home, ".x5ch_history.json")
  QUEUE_FILE   = File.join(Dir.home, ".x5ch_queue.json")
  LOCK_FILE    = File.join(Dir.home, ".x5ch.lock")
  PID_FILE     = File.join(Dir.home, ".x5ch.pid")
  CACHE_EXPIRATION = 300
  USER_AGENT = 'w3m/0.5.3'
end
