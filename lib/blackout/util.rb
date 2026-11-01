# frozen_string_literal: true

# Without a locale, ENV and ARGV arrive as ASCII-8BIT and matching them
# against a UTF-8 regex raises. Tag them explicitly.
def utf8(str)
  str&.dup&.force_encoding(Encoding::UTF_8)
end

# The host splits an item's text from its parameters on '|' and one menu
# item from the next on a newline, so anything from the network loses
# both. Length is capped as well: a 100 KB headline would otherwise
# stretch the menu across the screen.
def safe(str, limit = 200)
  # scrub before anything else: an invalid byte makes every later match
  # raise. Control characters go too — a NUL or an escape sequence in a
  # menu item is never something a source meant to send.
  # Bidi overrides and zero-width characters go with the control ones:
  # they are invisible in a menu item but reorder or hide what it says,
  # and nothing a schedule source sends needs them.
  v = str.to_s.scrub('')
         .delete("\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F")
         .delete("\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF")
         .delete('|').gsub(/[[:space:]]+/, ' ').strip
  v.length > limit ? "#{v[0, limit]}…" : v
end

# A parameter value (href=, bash= and friends) cannot contain spaces:
# the rest of the line would become separate parameters. Network data
# that does not look like a safe URL fragment is dropped.
def url_part(str)
  v = str.to_s
  v.match?(/\A[\w.~-]{1,120}\z/) ? v : nil
end

# Sources differ: the primary one sends ISO in UTC, the mirrors send an
# already formatted string. Normalise both to local time.
# A link taken from the feed is printed as an href= value, so it must
# have no spaces and must point where we say it does. Anything that is
# not a news page on that host simply is not shown.
def news_url(str)
  v = str.to_s
  ok = %r{\Ahttps://(alerts\.energy/news|t\.me/[\w.-]{1,64})/[\w./-]{1,160}\z}
  v.match?(ok) ? v : nil
end

def fmt_updated(str)
  v = safe(str)
  return v unless v.match?(/\A\d{4}-\d{2}-\d{2}T/)

  Time.parse(v).localtime.strftime('%d.%m %H:%M')
rescue StandardError
  v
end

# How long ago a schedule was published. The mirrors commit about twice
# a day, so what looks like today's plan can be twelve hours old and
# already superseded — the timestamp alone did not make that obvious.
def age_phrase(published)
  return nil unless published

  mins = ((Time.now - published) / 60).to_i
  return nil if mins.negative?
  return 'щойно' if mins < 60

  hours = mins / 60
  hours < 24 ? "#{hours} год тому" : "#{hours / 24} дн. тому"
end

def fmt(minutes)
  format('%d:%02d', minutes / 60, minutes % 60)
end
