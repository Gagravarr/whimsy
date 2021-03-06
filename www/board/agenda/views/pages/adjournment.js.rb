#
# Secretary version of Adjournment section: shows todos
#

class Adjournment < React
  def initialize
    Todos.set({
      add: [],
      remove: [],
      establish: [],
      loading: true,
      fetched: false
    })
  end

  def render
    _section.flexbox do
      _section do
        _pre.report @@item.text

        if not Todos.loading or Todos.fetched
          _h3 'Post Meeting actions'

          if 
            Todos.add.empty? and Todos.remove.empty? and 
            Todos.establish.empty?
          then
            if Todos.loading
              _em 'Loading...'
            else
              _p.comment 'complete'
            end
          end
        end

        unless Todos.add.empty?
          _TodoActions action: 'add'
        end

        unless Todos.remove.empty?
          _TodoActions action: 'remove'
        end

        unless Todos.establish.empty?
          _EstablishActions action: 'remove'
        end
      end

      _section do
        minutes = Minutes.get(@@item.title)
        if minutes
          _h3 'Minutes'
          _pre.comment minutes
        end
      end
    end
  end

  # check for minutes being completed on first load
  def componentDidMount()
    self.componentDidUpdate()
  end

  # fetch secretary todos once the minutes are complete
  def componentDidUpdate()
    if Minutes.complete and Todos.loading and not Todos.fetched
      Todos.fetched = true
      fetch "secretary-todos/#{Agenda.title}", :json do |todos|
        Todos.set todos
        Todos.loading = false
      end
    end
  end
end

########################################################################
#                          Add, Remove chairs                          #
########################################################################

class TodoActions < React
  def initialize
    @checked = {}
    @disabled = true
    @people = []
  end

  # check for minutes being completed on first load
  def componentDidMount()
    self.componentWillReceiveProps()
  end

  # update check marks based on current Todo list
  def componentWillReceiveProps()
    @people = Todos[@@action]

    # uncheck people who were removed
    for id in @checked
      unless @people.any? {|person| person.id == id}
        @checked[id] = false
      end
    end

    # check people who were added
    @people.each do |person|
      if @checked[person.id] == undefined
        if not person.resolution or Minutes.get(person.resolution) != 'tabled'
          @checked[person.id] = true 
        end
      end
    end

    self.refresh()
  end

  def refresh()
    # disable button if nobody is checked
    disabled = true
    for id in @checked
      disabled = false if @checked[id]
    end
    @disabled = disabled

    self.forceUpdate()
  end

  def render
    if @@action == 'add'
      _p 'Add to pmc-chairs:'
    else
      _p 'Remove from pmc-chairs:'
    end

    _ul.checklist @people do |person|
      _li do
        _input type: 'checkbox', checked: @checked[person.id],
          onChange:-> {
            @checked[person.id] = !@checked[person.id]
            self.refresh()
          }

        _a person.id,
          href: "https://whimsy.apache.org/roster/committer/#{person.id}"
        _ " (#{person.name})"

        if @@action == 'add' and person.resolution
        console.log person
          resolution = Minutes.get(person.resolution)
          if resolution
            _ ' - '
            _Link text: resolution, href: Todos.link(person.resolution)
          end
        end
      end
    end

    _button.checklist.btn.btn_default 'Submit', disabled: @disabled,
      onClick: self.submit
  end

  def submit()
    @disabled = true

    data = {}
    data[@@action] = @checked

    post "secretary-todos/#{Agenda.title}", data do |todos|
      @disabled = false
      Todos.set todos
    end
  end

  # launch email client, pre-filling the destination, subject, and body
  def launch_email_client()
    people = []
    @people.each do |person|
      people << "#{person.name} <#{person.email}>" if @checked[person.id]
    end
    destination = "mailto:#{people.join(',')}?cc=board@apache.org"

    subject = "Congratulations on your new role at Apache"
    body = "Dear new PMC chairs,\n\nCongratulations on your new role at " +
    "Apache. I've changed your LDAP privileges to reflect your new " +
    "status.\n\nPlease read this and update the foundation records:\n" +
    "https://svn.apache.org/repos/private/foundation/officers/advice-for-new-pmc-chairs.txt" +
    "\n\nWarm regards,\n\n#{Server.username}"

    window.location = destination +
      "&subject=#{encodeURIComponent(subject)}" +
      "&body=#{encodeURIComponent(body)}"
  end
end

########################################################################
#                          Establish actions                           #
########################################################################

class EstablishActions < React
  def initialize
    @checked = {}
    @disabled = true
    @podlings = []
  end

  # check for minutes being completed on first load
  def componentDidMount()
    self.componentWillReceiveProps()
  end

  # update check marks based on current Todo list
  def componentWillReceiveProps()
    @podlings = Todos.establish

    # uncheck podlings that were removed
    for name in @checked
      unless @podlings.any? {|podling| podling.name == name}
        @checked[name] = false
      end
    end

    # check podlings that were added
    @podlings.each do |podling|
      if @checked[podling.name] == undefined
        if not podling.resolution or Minutes.get(podling.resolution) != 'tabled'
          @checked[podling.name] = true 
        end
      end
    end

    self.refresh()
  end

  def refresh()
    # disable button if nobody is checked
    disabled = true
    for id in @checked
      disabled = false if @checked[id]
    end
    @disabled = disabled

    self.forceUpdate()
  end

  def render
    _p do
      _a 'Establish pmcs:', 
        href: 'https://infra.apache.org/officers/tlpreq'
    end

    _ul.checklist @podlings do |podling|
      _li do
        _input type: 'checkbox', checked: @checked[podling.name],
          onChange:-> {
            @checked[podling.name] = !@checked[podling.name]
            self.refresh()
          }

        _span podling.name

        resolution = Minutes.get(podling.resolution)
        if resolution
          _ ' - '
          _Link text: resolution, href: Todos.link(podling.resolution)
        end
      end
    end

    _button.checklist.btn.btn_default 'Submit', disabled: @disabled,
      onClick: self.submit
  end

  def submit()
    @disabled = true
    data = {establish: @checked}

    post "secretary-todos/#{Agenda.title}", data do |todos|
      @disabled = false
      Todos.set todos
    end
  end
end


########################################################################
#                             shared state                             #
########################################################################

class Todos
  def self.set(value)
    for attr in value
      Todos[attr] = value[attr]
    end
  end

  # find corresponding agenda item
  def self.link(title)
    link = nil
    Agenda.index.each do |item|
      link = item.href if item.title == title
    end
    return link
  end
end
