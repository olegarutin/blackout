# frozen_string_literal: true

# Net::HTTP.get has no timeouts: a stalled connection would hold the
# process forever while the menu-bar host starts a new one every minute.
MAX_BODY  = 2 * 1024 * 1024 # real files are 15-300 KB
OPEN_TIME = 5               # seconds to open the connection
READ_TIME = 8               # seconds to read the response

# A conditional GET: unchanged data comes back as 304 with no body.
# The Kyiv file is 300 KB, so this is the difference between 475 MB and
# a few MB a day. Returns [body or nil, new etag].
def http_get(url, etag = nil)
  uri = URI(url)
  raise "refusing non-https url: #{uri.scheme}" unless uri.scheme == 'https'

  Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                      open_timeout: OPEN_TIME,
                                      read_timeout: READ_TIME) do |http|
    req = Net::HTTP::Get.new(uri.request_uri)
    req['If-None-Match'] = etag if etag

    http.request(req) do |res|
      return [nil, etag] if res.is_a?(Net::HTTPNotModified)
      raise "http #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      # Check the cap while reading: res.body would first pull whatever
      # the server sends into memory and only then let us object
      body = ''.b
      res.read_body do |chunk|
        body << chunk
        raise 'response too large' if body.bytesize > MAX_BODY
      end

      # Net::HTTP returns ASCII-8BIT; tag it UTF-8 so the cache write
      # and the JSON parse behave predictably
      return [body.force_encoding(Encoding::UTF_8), res['etag']]
    end
  end
end
