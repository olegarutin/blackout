# frozen_string_literal: true

# Net::HTTP.get has no timeouts: a stalled connection would hold the
# process forever while the menu-bar host starts a new one every minute.
MAX_BODY  = 2 * 1024 * 1024 # real files are 15-300 KB
OPEN_TIME = 5               # seconds to open the connection
READ_TIME = 8               # seconds to read the response

# A conditional GET: unchanged data comes back as 304 with no body.
# The Kyiv file is 300 KB, so this is the difference between 475 MB and
# a few MB a day. Returns [body or nil, new etag].
# How long a host that refused us is left alone.
DENY_BACKOFF = 1800

# Keyed by host AND first path segment: the same host can close its API
# while still publishing an RSS feed it asks to be read, and one refusal
# must not take the other down with it.
def deny_marker(uri)
  key = "#{uri.host}#{uri.path[%r{\A/[^/]*}]}"
  File.join(CACHE, "deny-#{key.gsub(/[^\w.-]/, '_')}")
end

def deny_path(uri)
  ensure_dir(CACHE)
  FileUtils.touch(deny_marker(uri))
rescue StandardError
  nil
end

def denied?(uri)
  m = deny_marker(uri)
  File.exist?(m) && (Time.now - File.mtime(m)) < DENY_BACKOFF
end

def http_get(url, etag = nil)
  uri = URI(url)
  raise "refusing non-https url: #{uri.scheme}" unless uri.scheme == 'https'
  raise "backing off from #{uri.host}#{uri.path}" if denied?(uri)

  Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                      open_timeout: OPEN_TIME,
                                      read_timeout: READ_TIME) do |http|
    req = Net::HTTP::Get.new(uri.request_uri)
    req['If-None-Match'] = etag if etag
    # The primary source closed its API on 27 October 2026 and now wants
    # a key. There is no public sign-up, so this stays empty for most
    # people and the mirrors carry the app; whoever is given one puts it
    # in the config and everything works again.
    key = api_key_for(uri.host)
    req['Authorization'] = "Bearer #{key}" if key

    http.request(req) do |res|
      return [nil, etag] if res.is_a?(Net::HTTPNotModified)

      # A host that answered 401 or 403 means it, and the plugin runs
      # every minute on every machine. Stand back for a while instead of
      # knocking 1440 times a day at a door that was closed on purpose.
      deny_path(uri) if [401, 403].include?(res.code.to_i)
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
