#!/usr/bin/env ruby
$LOAD_PATH.unshift File.realpath(File.expand_path('../../lib', __FILE__))

require 'whimsy/asf'
require 'date'
require 'builder'
require 'ostruct'
require 'nokogiri'
require 'net/https'
require 'fileutils'
require 'wunderbar'

Wunderbar.log_level = 'info' unless Wunderbar.logger.info? # try not to override CLI flags

# Add datestamp to log messages (progname is not needed as each prog has its own logfile)
Wunderbar.logger.formatter = proc { |severity, datetime, progname, msg|
      "_#{severity} #{datetime} #{msg}\n"
    }

# for monitoring purposes
at_exit do
  if $! and not $!.instance_of? SystemExit
    msg = "#{$!.backtrace.first} #{$!.message}" rescue $!
    puts "\n*** Exception #{$!.class} : #{msg} ***"
  end
  Wunderbar.info "Finished #{__FILE__}"
end

Wunderbar.info "Starting #{__FILE__}"

# destination directory
SITE_MINUTES = ASF::Config.get(:board_minutes) ||
  File.expand_path('../../www/board/minutes', __FILE__)

# list of SVN resources needed
resources = {
  TEMPLATES: 'asf/infrastructure/site/trunk/templates',
  INCUBATOR_SITE_AUTHOR: 'asf/incubator/public/trunk/content',
  SVN_SITE_RECORDS_MINUTES:
    'asf/infrastructure/site/trunk/content/foundation/records/minutes',
  BOARD: 'private/foundation/board'
}

# verify that the SVN resources can be found
resources.each do |const, location|
  Kernel.const_set const, ASF::SVN[location]
  unless Kernel.const_get const
    STDERR.puts 'Unable to locate local checkout for ' +
      "https://svn.apache.org/repos/#{location}"
    exit 1
  end
end

incubator = URI.parse('http://incubator.apache.org/')

# quick exit if everything is up to date
if File.exist? "#{SITE_MINUTES}/index.html"
  input = Dir["#{SVN_SITE_RECORDS_MINUTES}/*/board_minutes_20*.txt",
    "#{TEMPLATES}/index.html", # if the template changes, we need to regenerate
    "#{BOARD}/board_minutes_20*.txt"].
    map {|name| File.stat(name).mtime}.push(File.stat(__FILE__).mtime).max
  exit if File.stat("#{SITE_MINUTES}/index.html").mtime >= input
end

# mapping of committee names to canonical names (generally from ldap)
canonical = Hash.new {|hash, name| name}
canonical.merge! \
    'conference planning'         => 'concom',
    'conferences'                 => 'concom',
    'security team'               => 'security',
    'c++ standard library'        => 'stdcxx'

# extract podling information
site = {}
ASF::Podling.list.each do |podling|
  if podling.display_name.downcase != podling.name
    canonical[podling.display_name.downcase] = podling.name
  end

  if podling.status == 'graduated' and podling.enddate
    next if Date.today - podling.enddate > 90
  end

  site[podling.name] = {
    name:   podling.display_name,
    status: podling.status,
    link:   incubator + "projects/#{podling.name}.html",
    text:   podling.description
  }
end

# parse site information
index = File.read("#{TEMPLATES}/index.html")
projects = index[/<section id="projects-list".*?<\/section>/m]
projects.scan(/<a href="(.*?)" title="(.*?)">(.*?)</).each do |link, text, name|
  site[canonical[name.downcase]] = {:name => name, :link => link, :text => text}
end

skeleton = File.read("#{TEMPLATES}/index.html")
projects = skeleton[/<section id="projects-list">(.*?)<\/section>/m,1]
projects.scan(/<a href="(.*?)" title="(.*?)">(.*?)</).each do |link, text, name|
  cname = canonical[name.downcase]
  link = 'https://www.apache.org' + link if link =~ /^\//
  site[cname] = {:name => name, :link => link, :text => text}
end

# parse the calendar for layout info (note: hack for &raquo)
CALENDAR = URI.parse 'https://www.apache.org/foundation/board/calendar.html'
http = Net::HTTP.new(CALENDAR.host, CALENDAR.port)
http.use_ssl = true
http.verify_mode = OpenSSL::SSL::VERIFY_NONE
get = Net::HTTP::Get.new CALENDAR.request_uri
$calendar = Nokogiri::HTML(http.request(get).body.gsub('&raquo','&#187;'))

# add some style
style = Nokogiri::XML::Node.new "style", $calendar
style.content = %{
  table {
    border: 1px solid #ccc;
    margin-botton: 10px;
    width: 100%;
    border-collapse: collapse;
    border-spacing: 0;
  }

  tbody th, tbody td {
    border-bottom: 1px solid #ccc;
    border-top: 1px solid #ccc;
    padding: 0.2em 1em;
  }

  pre.report {
    color: black;
    font-family: Consolas,monospace
  }
}
$calendar.at('head').add_child(style)

# Make links absolute
%w(a img link script).each do |name|
  $calendar.search(name).each do |element|
    element['href'] = (CALENDAR + element['href'].strip).to_s if element['href']
    element['src'] = (CALENDAR + element['src'].strip).to_s if element['src']
  end
end

# Dir.chdir(SVN_SITE_RECORDS_MINUTES) { system 'svn update' }

agenda = {}

posted = Dir["#{SVN_SITE_RECORDS_MINUTES}/*/board_minutes_20*.txt"].sort
unapproved = Dir["#{BOARD}/board_minutes_20*.txt"].sort

FileUtils.mkdir_p SITE_MINUTES

(posted+unapproved).each do |txt|
  date = $1 if txt =~ /(\d\d\d\d_\d\d_\d\d)/
  next unless date
  minutes = open(txt) {|file| file.read}
  print "\r#{date}"
  $stdout.flush
  pending = {}

  # parse Attachments (includes both Officer Reports and Committee Reports)
  minutes.scan(/
    -{41}\n                        # separator
    Attachment\s\s?(\w+):[ ](.+?)\n # Attachment, Title
    .(.*?)\n                       # report
    (?=-{41,}\n(?:End|Attach))     # separator
  /mx).each do |attach,title,text|
    title.sub! /Special /, ''
    title.sub! /Requested /, ''
    title.sub! /(^| )Report To The Board( On)?( |$)/i, ''
    title.sub! /^Board Report for /, ''
    title.sub! /^Status [Rr]eport for (the )?/, ''
    title.sub! /^Report from the VP of /, ''
    title.sub! /^Report from the /i, ''
    title.sub! /^Status report for the /i, ''
    title.sub! /^Apache /, ''
    title.sub! /^\/ /, ''
    title.sub! /\s+\[.*\]\s*$/, ''
    title.sub! /\sTeam$/, ''
    title.sub! /\s[Cc]ommittee?\s*$/, ''
    title.sub! /\s[Pp]roject\s*$/, ''
    title.sub! /\sPMC$/, ''

    title.sub! /^Logging$/, 'Logging Services'
    title.sub! 'stdcxx', 'C++ Standard Library'
    title.sub! 'Cxx Standard Library', 'C++ Standard Library'
    title.sub! 'Conferences', 'Conference Planning'
    title.sub! /Fund[- ][rR]aising/, 'Fundraising'
    title.sub! 'Geroniomo', 'Geronimo'
    title.sub! "Infrastructure (President's)", 'Infrastructure'
    title.sub! 'Java Community Process', 'JCP'
    title.sub! 'James', 'JAMES'
    title.sub! 'TomEE (OpenEJB)', 'TomEE'
    title.sub! 'OpenEJB', 'TomEE'
    title.sub! 'Public Relations Commitee', 'Public Relations'
    title.sub! /Security$/, 'Security Team'
    title.sub! /^Infrastructure .*/, 'Infrastructure'
    title.sub! /^Labs .*/, 'Labs'
    title.sub! 'TCL', 'Tcl'
    title.sub! 'Web services', 'Web Services'
    title.sub! 'ASF Rep. for W3C', 'W3C Relations'

    next if title.strip.empty?
    next if text.strip.empty? and title =~ /Intentionally (left )?Blank/i
    next if text.strip.empty? and title =~ /There is No/i

    report = pending[attach] || OpenStruct.new
    report.meeting = date
    report.attach = attach
    report.title = title.strip #.downcase
    report.text = text

    if title =~ /budget|spending/i
      report.subtitle = title
      report.title = 'Budget'
      report.attach = '@' + attach
    elsif title =~ /Contributor License Agreement/
      report.subtitle = title
      report.title = 'Legal Affairs'
      report.attach = '1' + attach
    elsif title =~ /P(rofit-and-|&)L(oss)? Report/
      report.subtitle = title
      report.title = 'Treasurer'
      report.attach = '1' + attach
    elsif title =~ /alleged JBoss IP infringement/
      report.subtitle = title
      report.title = 'Alleged JBoss IP Infringement'
      report.attach = '@' + attach
    end

    pending[attach] = report

    if title == 'Incubator' and text
      sections = text.split(/\nStatus [rR]eport (.*)\n=+\n/)
      sections = text.split(/\n[-=][-=]+\n\s*([a-zA-Z].*)\n\n/) if sections.length < 9
      sections = [''] if sections.include? 'FAILED TO REPORT'
      sections = text.split(/\n(\w+)\n-+\n\n/) if sections.length < 9
      sections = text.split(/\n=+\s+([\w.]+)\s+=+\n+/) if sections.length < 9

      prev = nil

      if sections.length > 1
        report.text = sections.shift 
        sections.each_slice(2) do |title, text|
          title.sub! /^regarding /, ''
          title.sub! /^for /, ''
          title.sub! /^from /, ''
          title.sub! /^the /, ''
          title.sub! /\sPPMC$/, ''

          if title =~ /Apache (.*) is a/
            text = title + "\n" + text
            title = $1
          end

          if title =~ /(.*) has been incubating/
            text = title + "\n" + text
            title = $1
          end

          if title =~ /(.*) -- (DID NOT REPORT)/
            text = $2 + "\n" + text
            title = $1
          end

          if title =~ /(.*?) - (.*)/
            text = $2 + "\n" + text
            title = $1
          end

          if title =~ /(.*? sponsored) incubation \((.*)\)/
            text = $2 + "\n" + text
            title = $1
          end

          next if title == 'April 2011 podling reports'

          title.sub! 'ACE', 'Ace'
          title.sub! 'Bean Validation', 'BeanValidation'
          title.sub! 'Bluesky', 'BlueSky'
          title.sub! 'Easyant', 'EasyAnt'
          title.sub! 'Callback', 'Cordova'
          title.sub! 'Empire-DB', 'Empire-db'
          title.sub! 'IVY', 'Ivy'
          title.sub! 'JackRabbit', 'Jackrabbit'
          title.sub! 'Juice', 'JuiCE'
          title.sub! 'log4php', 'Log4php'
          title.sub! 'lucene4c', 'Lucene4c'
          title.sub! 'Lucene.NET', 'Lucene.Net'
          title.sub! 'Ode', 'ODE'
          title.sub! 'ODFToolkit', 'ODF Toolkit'
          title.sub! 'OpenOffice.org', 'OpenOffice'
          title.sub! 'OpenEJB', 'TomEE'
          title.sub! 'Socialsite', 'SocialSite'
          title.sub! 'stdcxx', 'C++ Standard Library'
          title.sub! 'STDCXX', 'C++ Standard Library'
          title.sub! /\s+\(.*\)$/, ''
          title.sub! /^Apache(: Project)?/, ''

          if %w(Mentors Committers).include? title
            prev.text += "\n== #{title}==\n\n#{text}" if prev
            next
          end

          report = OpenStruct.new
          report.meeting = date
          report.attach = '.' + title
          report.title = title.strip
          report.text = text
          pending[report.attach] = report

          prev = report
        end
      end
    end
  end

  # parse Officer and Committee Reports for owners and comments
  minutes.scan(/
    \[([^\n]+)\]\n\n                  # owners
    \s{7}See\sAttachment\s\s?(\w+)    # attach
    (.*?)\n                           # comments
    \s\s\s\s?\w                       # separator
  /mx).each do |owners,attach,comments|
    report = pending[attach] || OpenStruct.new
    report.meeting = date
    report.attach = attach
    report.owners = owners
    report.comments = comments.strip
    pending[attach] = report
  end

  # fill in comments from missing reports
  ['Committee', 'Additional Officer'].each do |section|
    reports = minutes[/^ \d\. #{section} Reports(\s*(\n|  .*\n)+)/,1]
    next unless reports
    reports.split(/^    (\w+)\./)[1..-1].each_slice(2) do |attach, comments|
      next if attach.length > 2
      owners = comments[/\[([^\n]+)\]/,1]
      next if comments.include? 'See Attachment'
      comments.sub! /.*\s+\n/, ''
      next if comments.empty?
      attach = ('A'..attach).count.to_s if section == 'Additional Officer'

      report = pending[attach] || OpenStruct.new
      report.meeting = date
      report.attach = attach
      report.owners = owners
      report.comments = comments.strip
      pending[attach] = report
    end
  end

  # parse Action Items
  minutes.scan(/
    \n\s+(\w+)\.\s                    # attach
    Review\sOutstanding\s(Action\sItems)\n\n?
    (.*?)                             # text
    \n\s?\d                           # separator
  /mx).each do |attach, title, text|
    report = OpenStruct.new
    report.title ||= title #.downcase
    report.meeting = date
    report.attach = '+' + title
    text.gsub! /^\s?\d+\.\s.*\s*\Z/, ''
    report.text = text.gsub Regexp.new('^'+text.match(/^ */)[0]), '' if text
    pending[title] = report
  end

  # parse other agenda items
  minutes.scan(/
    \n\s*(\w+)\.\s                    # attach
    (Discussion\sItems|Unfinished\sBusiness|New\sBusiness|Announcements)\n
    (.*?)                             # text
    (?=\n\s?\d)                       # separator
  /mx).each do |attach, title, text|
    next if text.strip.empty?
    next if text =~ /\A\s*none\.?\s*\Z/i
    next if text =~ /\A\s*no unfinished business\.?\s*\Z/i
    report = OpenStruct.new
    report.title ||= title #.downcase
    report.meeting = date
    report.attach = '+' + title
    report.text = text.strip
    pending[title] = report
  end

  # parse Special Orders
  orders = minutes.split(/^ \d\. Special Orders/,2).last.split(/^ \d\./,2).first
  orders.scan(/
    \s{4}([A-Z])\.          # agenda item
    \s+(.*?)\n\s*\n         # title
    (.*?)                   # text
    (?=\n\s{4,5}[A-Z]\.\s|\z) # next section
  /mx).each do |attach,title,text|
    next if title.count("\n")>1
    report = OpenStruct.new
    title.sub! /(^|\n)\s*Resolution R\d:/, ''
    title.sub!(/^Resolution (\[R\d\]|to|for) ./) {|c| c[-1..-1].upcase}
    title.sub! /\.$/, ''
    report.title ||= title.strip
    report.meeting = date
    report.attach = '@' + title
    report.text = text.strip

    rules = [
      :X, 2, /Terminat(e|ion of) the (.+?) (Project|PMC|Committee)/,
      :X, 1, /Separate (.+?) from the Apache Software Foundation/,

      :E, 1, /Establishing a PMC for a (.*) project/,
      :E, 1, /Establish (.+?) as a top level project/,
      :E, 4, /Estab?lish(ing|ment)? (of )?(the |an )?(.+?) (board )?(PMC|[pP]roject|[cC]ommittee)$/,
      :E, 2, /Creat(e|ion of) the (.+?) (Project|PMC)/,
      :E, 2, /To (re-establish|create) the (.+?) PMC/,
      :E, 2, /Reestablish(ing the)? (.+?)( Project| Committee | Team)/,
      :E, 1, /^Apache (.+?) Project$/,


      :C, 3, /(Change|Appoint).* Vice President of (the )?(.+)/,
      :C, 2, /(Appoint|Establish) a new (.+?) PMC Chair/,
      :C, 1, /New Vice President for the (.+?) PMC/,
      :C, 1, /Appoint.* as the (.*?) of the ASF/,
      :C, 1, /Appointment of (.*?) Committee Chair/,
      :C, 3, /Appoint(ing a)? new [cC]hair (for|of the) (.*?)( Project|$)/,
      :C, 1, /Alter the Chair of the (.+?) Project/,
      :C, 2, /[cC]hange (the )?[cC]hair of the (.+?) (Project|PMC)/,
      :C, 3, /[Cc]hang(e|ing) (to )?the (.+?) (Project |PMC )?Chair/,
      :C, 2, /Change (of|the) (.+?) (PMC |Project |Committee )Chair/,
      :C, 1, /Resolution to change the (.+?) Chair/,
      :C, 1, /PMC chair change for (.+)/,
      :C, 1, /Change PMC [Cc]hair for (.+?) Project/,
      :C, 3, /Appoint a (new )?(chair for |Vice President of )(.+)/,
      :C, 1, /Appoint .*? as (.+?) chairman/,
      :C, 1, /Change Chair for Apache (.+)/,

      :M, 1, /Reboot the (.+?) (PMC|Committee)/,
      :M, 1, /(.+?) election of new PMC/,
      :M, 2, /Update (membership of the )?(.+?) Committee/,
      :M, 1, /Change to the (.*)? Committee Membership/,
      :M, 1, /Change the Apache (.*) Project Name/,
       1, 1, /Update ?(audit.+?) Membership/i,
      :M, 1, /Update ?(.+?) Membership/,
      :R, 1, /Rename.* to the ?(.+?) Project/,

      '@', 1, /(.*) Renewal/,

      :C, 'Conference Planning', /Conferences? Committee/,

      '@', 'Budget', /Spending Resolution/i,
      '@', 'Budget', /Budget/i,
      '@', 'Bylaws', /Bylaw/i,
      '@', 'Chief Media Officer', /Chief Media Officer/i,

      1, 'JCP', /Java Community Process/,
      1, 'JCP', /JCP/,
      1, 'Public Relations', /Public Relations/i,
      1, 'Marketing and Publicity', /Press/i,
      1, 'Legal Affairs', /License/i,
      1, 'Legal Affairs', /Copyright/i,
      1, 'Legal Affairs', /contributor agreement/i,
      1, 'Legal Affairs', /CLA/,
      1, 'Legal Affairs', /[MG]PL/,
      1, 'Brand Management', /use.*feather/,
      1, 'Brand Management', /Trademark/,
      1, 'Brand Management', /use.*Apache name/,
      1, 'Travel Assistance', /TAC/,
      1, 'Travel Assistance', /Travel Assistance/,
      1, 'Conference Planning', /Conference Planning/,
      1, 'Fundraising', /Fundraising/,
      1, 'Audit', /Audit/i,

      :C, 'Public Relations', /Appoint Brian Fitzpatrick as a Vice President/,

      '@', 'Appoint Executive Officers', /Appoint(ment of)? (new |ASF )?[oO]fficers/,
      '@', 'Appoint Executive Officers', /Election of Officers/,
      '@', 'Appoint Executive Officers', /Officer Appointments/i,
      '@', 'Set Date for Members Meeting', /date.* member'?s meeting/i,
      '@', 'PMC Membership Change Process', /Empower PMC chairs to change the membership/i,
      '@', 'Secretarial Assistant', /Approve contract with Jon Jagielski/,
      '@', 'Alleged JBoss IP Infringement', /alleged JBoss IP infringe?ment/,
      '@', 'Discussion Items', /^Discuss/
    ]

    rules.each_slice(3) do |prefix, select, pattern|
      match = pattern.match(report.title)
      if match
        report.subtitle = report.title
        if select.is_a? Fixnum
          report.title = match[select]
        else
          report.title = select
        end
        report.attach = "#{prefix}#{report.attach}"
        break
      end
    end

    report.title.sub! /^Apache /, ''
    report.title.sub! 'APR', 'Portable Runtime'
    report.title.sub! 'standing Audit', 'Audit'
    report.title.sub! /^HTTPD?$/, 'HTTP Server'
    report.title.sub! 'ISIS', 'Isis'
    report.title.sub! 'iBatis', 'iBATIS'
    report.title.sub! 'James', 'JAMES'
    report.title.sub! 'infrastructure', 'Infrastructure'
    report.title.sub! 'federated identity', 'Federated Identity'
    report.title.sub! 'Open for Business', 'OFBiz'
    report.title.sub! /^OpenEJB/, 'TomEE'
    report.title.sub! /Perl-Apache( PMC)?/, 'Perl'
    report.title.sub! /Public Relations Committee/, 'Public Relations'
    report.title.sub! 'PRC', 'Public Relations'
    report.title.sub! /Security$/, 'Security Team'
    report.title.sub! 'Apache/TCL', 'Tcl'

    pending[title] = report
  end

  # parse (Executive) Officer Reports
  execs = minutes[/Officer Reports(.*?)\n\s+\d+\./m,1]
  if execs
    execs.scan(/
      \n\s+(\w+)\.\s([^\n]*?)\n         # attach, title
      (.*?)                             # text
      (?=\n\s+\w\.\s|\Z)                # separator
    /mx).each do |attach, title, text|
      next unless text
      next unless title
      next if title.start_with? 'This interim budget shows a surplus'
      next if title.start_with? "President's discretionary fund returned to"

      title.sub! 'Executive VP', 'Executive Vice President'
      title.sub! 'Exec. V.P. and Secretary', 'Secretary'
      report = OpenStruct.new
      if title.include? ' ['
        report.owners = title.split(' [').last.sub(']','').strip
        title = title.split(' [').first
      end
      report.title ||= title.strip #.downcase
      report.title.gsub! /^V\.?P\.? of /, ''
      report.title.gsub! /\/Apache$/, ''
      report.title = 'Infrastructure' if report.title =~ /Infrastructure/
      report.title = 'Treasurer' if report.title =~ /Treasurer/
      report.meeting = date
      report.attach = '*' + title
      report.text = text
      pending[title] = report
    end
  end

  # Add to the running tally
  pending.each_value do |report|
    next if not report.title or report.title.empty?

    # flag unposted reports; exclude unposted special orders
    report.posted = posted.include? txt
    next if not report.posted and 
      (report.attach =~ /^[A-Z]?@/ or report.attach !~ /^[A-Z.]/)

    agenda[report.title] ||= []
    agenda[report.title] << report
  end
end

puts

# determine link for each report
link = {}
agenda.each do |title, reports|
  link[title] = title.sub('C++','Cxx').gsub(/\W/,'_') + '.html'
end

# Combine content produced here with the template fetched previously
def layout(title = nil)
  builder = Builder::XmlMarkup.new :indent => 2
  yield builder
  content = Nokogiri::HTML(builder.target!)
  if title
    $calendar.at('title').content = "Board Meeting Minutes - #{title}"
#   $calendar.at('h2').content = "Board Meeting Minutes - #{title}"
  else
    $calendar.at('title').content = "Board Meeting Minutes"
#   $calendar.at('h2').content = "Board Meeting Minutes"
  end
  stamp = DateTime.now.strftime '%Y-%m-%d %H:%M'
  section = $calendar.at('.container p strong').parent.parent
  paragraphs = section.search('p')
  paragraphs.first.children.last.content =
    paragraphs.first.children.last.content.sub 'is a', "was extracted (@ #{stamp}) from a"

  section.children.each {|child| child.remove}
  section.add_child paragraphs[0]
  section.add_child paragraphs[1]
  content.at('body').children.each {|child| section.add_child child}

  $calendar.to_xhtml
end

# output each individual report by owner
agenda.sort.each do |title, reports|
  puts title
  page = layout(title) do |x|
    info = site[canonical[title.downcase]]
    if info
      # site information found, link to it
      x.h1 do
        x.a info[:name], :href => info[:link], :title => info[:text]
      end
    else
      x.h1 title
    end
    reports.reverse.each do |report|
      x.h2 do
        if report.posted
          href = "http://apache.org/foundation/records/minutes/" +
            "#{report.meeting[0...4]}/board_minutes_#{report.meeting}.txt"
        else
          href = 'https://svn.apache.org/repos/private/foundation/board/' +
            "board_minutes_#{report.meeting}.txt"
        end

        x.a Date.parse(report.meeting.gsub('_','/')).strftime("%d %b %Y"),
          href: href, id: "minutes_#{report.meeting}"
        if report.owners
          x.span "[#{report.owners}]", :style => 'font-size: 14px'
        end
      end
      x.h3 report.subtitle if report.subtitle

      if report.posted
        text = report.text.gsub(/^\t+/) {|tabs| " " * (8*tabs.length)}
        text.gsub!(/ *$/, "")
        indent = text.scan(/^([ ]+)/).flatten.min.to_s.length - 1
        text.gsub! /^#{' '*indent}/, '' if indent > 0
        text = $1 + text if text =~ /\A\w.*\n(\s+)/
        text = text.to_s.rstrip
        x.pre text, class: 'report' unless text.strip.empty?

        if report.comments and report.comments.strip != ''
          report.comments.split(/\n\s*\n/).each do |p|
            x.p p, :style => "width: 40em"
          end
        elsif text.strip.empty?
          x.p {x.em 'A report was expected, but not received'}
        end
      elsif report.text.strip.empty?
        x.p {x.em 'A report was expected, but not received'}
      else
        x.p do
          x.em 'Report was filed, but display is awaiting the approval ' +
            'of the Board minutes.'
        end
      end
    end
  end

  dest = "#{SITE_MINUTES}/#{link[title]}"
  unless File.exist?(dest) and File.read(dest) == page
    open(dest, 'w') {|file| file.write page}
  end
end

# output index
agenda = agenda.sort_by {|title, reports| title.downcase}
page = layout do |x|
  x.h2 "Executive Officer Reports", :id => 'executive'
  x.ul do
    agenda.each do |title, reports|
      next unless reports.last.attach =~ /^\*/
      next if reports.length == 1
      x.li do
        x.a title, :href => link[title]
      end
    end
  end
  x.h2 "Additional Officer Reports", :id => 'officer'
  x.ul do
    agenda.each do |title, reports|
      next unless reports.last.attach =~ /^\d/
      next if reports.length == 1
      x.li do
        x.a title, :href => link[title]
      end
    end
  end
  x.h2 "Committee Reports", :id => 'committee'
  list = []
  agenda.each do |title, reports|
    next unless reports.last.attach =~ /^[A-Z]/
    next if reports.length == 1
    list << title
  end
  cols = 6
  slice = (list.length+cols-1)/cols
  x.table do
    (0...slice).each do |i|
      x.tr do
        (0...cols).each do |j|
          x.td do
            title = list[i+j*slice]
            if title
              info = site[canonical[title.downcase]]
              if info
                x.a title, :href => link[title], :title => info[:text]
              else
                x.em { x.a title, :href => link[title] }
              end
            end
          end
        end
      end
    end
  end
  x.h2 "Podling Reports", :id => 'podling'
  list = []
  agenda.each do |title, reports|
    next unless reports.last.attach =~ /^[.]/
    list << title
  end
  cols = 6
  slice = (list.length+cols-1)/cols
  x.table do
    (0...slice).each do |i|
      x.tr do
        (0...cols).each do |j|
          x.td do
            title = list[i+j*slice]
            if title
              info = site[canonical[title.downcase]]
              if info
                if %w{dormant retired}.include? info[:status]
                  x.em do
                    x.a title, :href => link[title], :title => info[:text]
                  end
                else
                  x.a title, :href => link[title], :title => info[:text]
                end
              else
                x.em { x.a title, :href => link[title] }
              end
            end
          end
        end
      end
    end
  end
  x.h2 "Repeating Special Orders", :id => 'orders'
  x.ul do
    agenda.each do |title, reports|
      next unless reports.last.attach =~ /^@/
      next if reports.length == 1
      x.li do
        x.a title, :href => link[title]
      end
    end
  end
  x.h2 "Other Attachments and Special Orders", :id => 'other'
  x.ul do
    other = {}
    agenda.each do |title, reports|
      next unless reports.length == 1
      next if reports.last.attach =~ /^[.]/
      other[reports.first.subtitle || title] = title
    end
    other.sort.each do |subtitle, title|
      x.li do
        x.a subtitle, :href => link[title]
      end
    end
  end
  x.h2 "Other Agenda Items", :id => 'agenda'
  x.ul do
    agenda.each do |title, reports|
      next unless reports.last.attach =~ /^\+/
      next if reports.length == 1
      x.li do
        x.a title, :href => link[title]
      end
    end
  end
end

open("#{SITE_MINUTES}/index.html", 'w') {|file| file.write page}

Wunderbar.info "Wrote #{SITE_MINUTES}/index.html"
