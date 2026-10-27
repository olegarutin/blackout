# frozen_string_literal: true

# Some operators publish their schedules through their own site API, in
# plain text. Reading those first-hand is the only way to see a revision
# made during the day: the community mirrors commit about twice a day,
# both times in the evening, so a schedule rewritten at ten in the
# morning does not reach them until night.

MONTHS = %w[січня лютого березня квітня травня червня липня серпня
            вересня жовтня листопада грудня].freeze

# "…(ГПВ) на 27 жовтня" → that date, with the year taken from today so
# the turn of a year does not read as ten months in the past.
def title_date(title, today = Date.today)
  m = title.to_s.match(/\sна\s+(\d{1,2})\s+(\p{L}+)/)
  return nil unless m

  month = MONTHS.index(m[2].downcase)
  return nil unless month

  d = Date.new(today.year, month + 1, m[1].to_i)
  if (d - today).to_i.abs > 180
    Date.new(today.year + (d < today ? 1 : -1), month + 1, m[1].to_i)
  else
    d
  end
rescue StandardError
  nil
end

# "1.1 12:00 - 14:00, 18:00 - 20:00" per line, one line per queue.
# Returns queue => the hours it is off, as 1..24 where N means [N-1, N).
def parse_outage_text(text)
  # Sites put a non-breaking space between the queue and its hours, and
  # \s does not match one. Normalise before matching.
  text.to_s.tr("\u00A0\u2009\u202F", ' ').each_line.with_object({}) do |line, acc|
    span = /\d{1,2}:\d{2}\s*[-–—]\s*\d{1,2}:\d{2}/
    m = line.match(/\A\s*(\d{1,2}\.\d{1,2})\s+(#{span}(?:\s*,\s*#{span})*)/)
    next unless m

    hours = m[2].scan(/(\d{1,2}):\d{2}\s*[-–—]\s*(\d{1,2}):\d{2}/).flat_map do |from, to|
      start = from.to_i
      finish = to.to_i.zero? ? 24 : to.to_i
      ((start + 1)..finish).to_a
    end
    acc[m[1]] = hours.uniq.sort unless hours.empty?
  end
end

# The operator's text, reshaped into the document the rest of the code
# already understands, so nothing downstream needs to know the source.
def as_operator_schedule(days, published)
  data = days.filter_map do |date, queues|
    next if queues.empty?

    groups = queues.to_h do |queue, off|
      ["GPV#{queue}", (1..24).to_h { |h| [h.to_s, off.include?(h) ? 'no' : 'yes'] }]
    end
    [date.to_time.to_i.to_s, groups]
  end.to_h
  return nil if data.empty?

  { 'lastUpdated' => published&.iso8601,
    'fact' => { 'data' => data,
                'update' => published&.strftime('%d.%m.%Y %H:%M'),
                'today' => Date.today.to_time.to_i } }
end
