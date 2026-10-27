# frozen_string_literal: true

# The grid operator publishes its system-state notices to a public
# Telegram channel, which is served to anyone without a login or a bot
# challenge — unlike its own website, which answers every automated
# client with a Cloudflare page, and unlike the aggregator API that
# closed on 27 October. This is the primary source, read first-hand.

# Messages of a channel's public page, newest last.
def telegram_posts(html, limit = 6)
  html.to_s.split(/<div class="tgme_widget_message[ "]/).drop(1).last(limit).filter_map do |chunk|
    body = chunk[%r{class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>}m, 1]
    next unless body

    post = chunk[%r{data-post="([\w.-]{1,64}/\d{1,9})"}, 1]
    { 'text' => telegram_text(body),
      'at' => chunk[/datetime="([^"]+)"/, 1],
      'link' => post && "https://t.me/#{post}" }
  end
end

# Telegram wraps its text in markup and escapes entities; line breaks
# carry meaning here, so they survive as newlines until safe() is called.
def telegram_text(body)
  unescape_xml(body.gsub(%r{<br\s*/?>}, "\n").gsub(/<[^>]+>/, '')).to_s.strip
end

# An oblast is named in running prose, so it arrives declined:
# "Харківська область" is written "у Харківській області". Matching on
# the stem of the first word covers every case form without a dictionary.
def oblast_stem(name)
  word = name.to_s.sub(/\Aм\.\s*/, '').split.first.to_s
  word.length > 5 ? word[0, word.length - 2] : word
end

# Oblasts the post names as newly de-energised. Only the sentences that
# say so are searched: the rest of a post mentions regions in other
# contexts — repairs finished, consumption, yesterday's figures — and
# matching those would put a warning on an oblast that is fine.
def oblasts_named(text, names)
  # Split on line breaks as well as sentence ends: the post is a list of
  # bullet lines, and a run-on split swallowed whole paragraphs.
  said = text.to_s.split(/(?<=[.!?])\s+|\n+/)
             .grep(/знеструмлен|без світла/i)
             .join(' ')
  return [] if said.empty?

  names.select do |n|
    stem = oblast_stem(n)
    !stem.empty? && said.include?(stem)
  end
end
