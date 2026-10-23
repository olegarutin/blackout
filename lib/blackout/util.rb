# Without a locale, ENV and ARGV arrive as ASCII-8BIT and matching them
# against a UTF-8 regex raises. Tag them explicitly.
def utf8(str)
  str.nil? ? nil : str.dup.force_encoding(Encoding::UTF_8)
end

# The host splits an item's text from its parameters on '|', so anything
# from the network has that character removed and its length capped —
# a 100 KB headline would otherwise stretch the menu across the screen.
def safe(str, limit = 200)
  v = str.to_s.delete('|').strip
  v.length > limit ? "#{v[0, limit]}…" : v
end

# A parameter value (href=, bash= and friends) cannot contain spaces:
# the rest of the line would become separate parameters. Network data
# that does not look like a safe URL fragment is dropped.
def url_part(str)
  v = str.to_s
  v.match?(%r{\A[\w.~-]{1,120}\z}) ? v : nil
end

# Sources differ: the primary one sends ISO in UTC, the mirrors send an
# already formatted string. Normalise both to local time.
def fmt_updated(str)
  v = safe(str)
  return v unless v.match?(/\A\d{4}-\d{2}-\d{2}T/)

  Time.parse(v).localtime.strftime('%d.%m %H:%M')
rescue StandardError
  v
end

def fmt(minutes)
  format('%d:%02d', minutes / 60, minutes % 60)
end
