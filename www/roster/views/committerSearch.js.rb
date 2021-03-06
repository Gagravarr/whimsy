class CommitterSearch < React
  def initialize
    @list = []
    @ready = false
    @search = ''
    @committers = []
  end

  def componentDidMount()
    # start with (possibly stale) data from local storage when available
    ls_committers = localStorage.getItem('roster-committers')
    if ls_committers
      @committers = JSON.parse(ls_committers)
      @ready = true
      self.change(target: {value: @search}) unless @search.empty?
    end

    # load fresh data from the server
    ls_committers = localStorage.getItem('roster-committers')
    Polyfill.require(%w(Promise fetch)) do
      fetch('committer/index.json', credentials: 'include').then {|response|
        response.json().then do |committers|
          @committers = committers
          @ready = true
          self.change(target: {value: @search}) unless @search.empty?
          localStorage.setItem('roster-committers', @committers.inspect)
        end
      }.catch {|error|
        console.log error
      }
    end
  end

  def change(event)
    @search = event.target.value

    search = @search.downcase().split(' ')

    list = []
    @list = list
    @committers.each do |person|
      if 
        search.all? {|part|
          person.id.include? part or
          person.name.downcase().include? part or
          person.mail.any? {|mail| mail.include? part}
        }
      then
        list << person
      end
    end
  end

  def render
    _label 'Search:', for: 'search-text'
    _input.search_text! autofocus: true, value: @search, onChange: self.change

    if @search.length
      if not @ready
        _p 'loading...'

      else
        search = @search.downcase().split(' ')
        list = @list

        if list.length == 0
          _p 'none found'
        elsif list.length > 99
          _p "#{list.length} entries match"
        else
          _table.table.table_hover do
            _thead do
              _tr do
                _th 'id'
                _th 'public name'
                _th 'email'
              end
            end

            _tbody do
              list.each do |person|
                _tr data_id: person.id, onDoubleClick: self.select do
                  _td {_a person.id, href: "committer/#{person.id}"}

                  if person.member
                    _td {_b person.name}
                  else
                    _td person.name
                  end

                  _td person.mail.first
                end
              end

              if @@add
                _tr.alert_success do
                  _td 'Double click on a row to add', colspan: 3
                end
              end
            end
          end

        end
      end
    end
  end

  def select(event)
    if @@add
      id = event.currentTarget.dataset.id
      person = @list.find {|person| person.id == id}
      @@add.call(person)
    end
  end
end
