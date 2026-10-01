# encoding: utf-8

require 'net/http'
require 'nokogiri'
require 'json'
require 'digest'
require 'date'
require 'time'
require 'uri'

# erdosproblems.com does not publish feeds, so the forum is scraped into Atom
# feeds here. A feed with location = erdos-forum picks a section of the forum
# index by the fragment of its feed url, e.g.
#   feed = https://www.erdosproblems.com/forum/#proof-claims
module ErdosForum
    FORUM_URL = 'https://www.erdosproblems.com/forum/'
    USER_AGENT = 'combinatorics-aggregator (+https://github.com/gdahia/combinatorics-aggregator)'
    SECTIONS = %w[proof-claims proof-expositions problem-threads].freeze
    # how many of the latest index entries of a section to follow
    MAX_THREADS = 15

    # scraped pages, kept so that a page is only fetched again when its index
    # entry changes
    class Page < ActiveRecord::Base
        self.table_name = 'erdos_forum_pages'
    end

    def self.fetch(feed_rec)
        logger = LogUtils::Logger.root
        section = URI(feed_rec.feed_url).fragment
        raise ArgumentError, "unknown forum section '#{section}'" unless SECTIONS.include?(section)

        ensure_table!
        entries = entries_for(section)
        raise "no entries found in forum section '#{section}'" if entries.empty?

        feed_xml = to_atom(feed_rec, entries)
        feed_md5 = Digest::MD5.hexdigest(feed_xml)
        if feed_rec.md5 == feed_md5
            logger.info "no change; md5 digests match; skipping parsing feed"
            return nil
        end
        feed_rec.update!(http_code: 200, http_etag: nil, http_last_modified: nil,
                         body: feed_xml, md5: feed_md5, fetched: Time.now)
        logger.info "OK - scraping feed '#{feed_rec.key}' - #{entries.size} entries"
        feed_xml
    rescue StandardError => e
        # skip the feed for this run; a partial feed would make pluto delete the missing items
        logger.error "*** error: fetching feed '#{feed_rec.key}' - [#{e.class.name}] #{e}"
        Pluto::Model::Activity.create!(text: "*** error: fetching feed '#{feed_rec.key}' - [#{e.class.name}] #{e}")
        nil
    end

    def self.ensure_table!
        connection = ActiveRecord::Base.connection
        return if connection.table_exists?(Page.table_name)
        connection.create_table(Page.table_name) do |t|
            t.string :section, null: false
            t.string :url, null: false
            t.string :validator
            t.text :entries
        end
    end

    def self.get(url, redirects = 3)
        response = Net::HTTP.get_response(URI(url), { 'User-Agent' => USER_AGENT })
        if response.is_a?(Net::HTTPRedirection) && redirects > 0
            return get(URI.join(url, response['location']).to_s, redirects - 1)
        end
        raise "HTTP status #{response.code} #{response.message} for #{url}" unless response.code == '200'
        Nokogiri::HTML(response.body.force_encoding(Encoding::UTF_8), nil, 'UTF-8')
    end

    # the latest entries of a section of the forum index (shared by all feeds of a run)
    def self.threads(section)
        @index ||= get(FORUM_URL)
        @index.css("ul##{section} li.thread-item").first(MAX_THREADS).map do |li|
            link = li.at_css('a.thread-title')
            uri = URI.join(FORUM_URL, link['href'])
            fragment = uri.fragment
            uri.fragment = nil
            { url: uri.to_s, problem: link.text.strip, fragment: fragment,
              posts: li.at_css('.badge')&.[]('title'), user: li.at_css('a.user-link')&.[]('href') }
        end
    end

    def self.entries_for(section)
        pages = threads(section).group_by { |thread| thread[:url] }
        Page.where(section: section).where.not(url: pages.keys).delete_all

        # proof claims and expositions are listed one by one in the index (the
        # fragment names them); comments are listed by thread
        by_thread = pages.values.flatten.none? { |thread| thread[:fragment] }
        entries_by_page = pages.map do |url, threads|
            validator = threads.map { |thread| thread.values_at(:fragment, :posts, :user).join(' ') }.sort.join("\n")
            entries = page_entries(section, url, validator)
            entries = entries.select { |entry| threads.any? { |thread| thread[:fragment] == entry['id'] } } unless by_thread
            entries.map do |entry|
                title = "Erdős Problem ##{threads.first[:problem]}: #{entry['label']}"
                title += " by #{entry['author']}" if entry['author']
                entry.merge('url' => "#{url}##{entry['id']}", 'title' => title)
            end
        end

        entries = entries_by_page.flatten
        if by_thread
            # threads further down the index were last active before all of these,
            # so the feed is complete from the latest post of the last thread on
            cutoff = entries_by_page.map { |page| page.map { |entry| entry['published'] }.max }.compact.min
            entries = entries.select { |entry| entry['published'] >= cutoff }
        end
        entries.sort_by { |entry| [entry['published'], entry['url']] }.reverse
    end

    def self.page_entries(section, url, validator)
        page = Page.find_or_initialize_by(section: section, url: url)
        if page.validator != validator
            sleep 1
            page.update!(validator: validator, entries: JSON.generate(scrape(section, get(url))))
        end
        JSON.parse(page.entries)
    end

    def self.scrape(section, doc)
        entries = case section
        when 'proof-claims'
            doc.css('article.proof-claim').map do |claim|
                body = claim.at_css('.post-body')
                submitted = body&.at_css('small')&.remove
                kind = body&.at_css('b')&.text.to_s.strip.downcase
                label = %w[full partial].include?(kind) ? "#{kind} proof claim" : 'proof claim'
                entry(claim['id'], label, submitted&.at_css('a'),
                      submitted&.text.to_s[/\d{4}-\d\d-\d\d \d\d:\d\d:\d\d/], '%Y-%m-%d %H:%M:%S', body)
            end
        when 'proof-expositions'
            doc.css('.proof-exposition').map do |exposition|
                meta = exposition.at_css('.proof-exposition-meta')
                entry(exposition['id'], 'proof exposition', meta&.at_css('strong'),
                      meta&.text.to_s[/\d{1,2} \w+ \d{4}/], '%d %b %Y',
                      exposition.at_css('.proof-exposition-content'))
            end
        when 'problem-threads'
            doc.css('ul.post-list li.post').map do |post|
                meta = post.at_css('.post-meta')
                entry(post['id'], 'comment', meta&.at_css('strong'),
                      meta&.at_css('a[href*="#post-"]')&.text, '%H:%M on %d %b %Y', post.at_css('.post-body'))
            end
        end.compact

        # every page of a problem starts with its statement; quote it above each entry
        statement = doc.at_css('.problem-text #content')&.inner_html.to_s.strip
        return entries if statement.empty?
        entries.each do |entry|
            entry['content'] = "<blockquote><b>Problem:</b> #{statement}</blockquote>" + entry['content']
        end
    end

    # the forum shows times in UTC
    def self.entry(id, label, author, date, date_format, body)
        return nil if id.nil? || body.nil?
        published = DateTime.strptime(date.to_s.strip, date_format).to_time.utc.iso8601
        { 'id' => id, 'label' => label, 'author' => author&.text&.strip,
          'published' => published, 'content' => body.inner_html.strip }
    rescue Date::Error
        nil
    end

    def self.to_atom(feed_rec, entries)
        Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
            xml.feed(xmlns: 'http://www.w3.org/2005/Atom') do
                xml.title feed_rec.title
                xml.id_ feed_rec.feed_url
                xml.link(href: FORUM_URL)
                xml.updated entries.first['published']
                entries.each do |entry|
                    xml.entry do
                        xml.title entry['title']
                        xml.id_ entry['url']
                        xml.link(href: entry['url'])
                        xml.published entry['published']
                        xml.updated entry['published']
                        xml.author { xml.name entry['author'] } if entry['author']
                        xml.content(entry['content'], type: 'html')
                    end
                end
            end
        end.to_xml
    end
end
