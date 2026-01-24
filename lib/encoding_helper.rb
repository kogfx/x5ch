require 'json'

module EncodingHelper
  def self.to_utf8(binary_string, content_type = nil)
    return binary_string if content_type && content_type.include?("application/json")
    begin
      binary_string.force_encoding('Windows-31J').encode('UTF-8', invalid: :replace, undef: :replace)
    rescue
      binary_string.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
    end
  end
end
