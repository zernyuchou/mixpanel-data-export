# Mixpanel Ruby Data Export Tool
#
# Copyright (c) 2015+ Appstronomy, LLC.
# See LICENSE.txt for details on use.

# Containing module for high-level classes dealing with the Mixpanel API service
# and/or querying that service.
module Mixpanel

  require 'csv'
  require 'fileutils'
  require_relative 'service'
  require_relative '../util/exporter_config'


  # Handles the orchestration of getting all of the event names, and requesting
  # a data export of each one of them, sending the result to a CSV file.
  # We output CSV files by date (directories) and then event (part of the filename).
  #
  # @author Sohail Ahmed, https://github.com/idStar
  class Exporter

    # @return [Mixpanel::Service]
    attr_reader :service

    # The names of all of the events we've been able to retrieve from Mixpanel.
    # @return [Array]
    attr_reader :event_names

    # The base output directory, as given to us by {Util::ExporterConfig}
    # @return [String]
    attr_reader :output_directory

    # The number of days ago to use as the start date of the export range,
    # as given to us by {Util::ExporterConfig}
    #
    # @return [Fixnum]
    attr_reader :from_days_ago

    # The number of days ago to use as the end date of the export range,
    # as given to us by {Util::ExporterConfig}
    #
    # @return [Fixnum]
    attr_reader :to_days_ago

    # Whether to create sub-folders for each distinct download date,
    # as given to us by {Util::ExporterConfig}
    #
    # @return [Boolean]
    attr_reader :create_subfolders_by_date

    # Whether to use event dates (as ranges) in the filenames of downloaded data,
    # as given to us by {Util::ExporterConfig}
    #
    # @return [Boolean]
    attr_reader :use_event_dates_in_filenames


    # Creates a new instance of Exporter, configured with our own Mixpanel::Service.
    def initialize
      configure_logging
      load_configuration
      create_csv_directory
      @service = Mixpanel::Service.new

      @logger.info 'Initialized Exporter instance.'
    end


    # Kicks off the services requests. First to get the event names. Second,
    # to download data for each event.
    def start
      @logger.info 'Started Mixpanel Data Export process.'

      # Retrieve the name of all known events:
      all_event_names = @service.event_names

      # Exclude or include a subset of events:
      if @events_to_exclude.count > 0
        @event_names = all_event_names - @events_to_exclude
        @logger.info "Requested to exclude events: #{@events_to_exclude.inspect}."
      elsif @events_to_include.count > 0
        @event_names = all_event_names & @events_to_include
        @logger.info "Requested to include events: #{@events_to_include.inspect}."
      else
        @event_names = all_event_names
      end

      # Log what we will be using:
      @logger.info "Will attempt download for the following events: #{@event_names.inspect}"
      @logger.info "Sending output to '#{csv_directory}'."
      @logger.info "Using date range {from days ago: #{@from_days_ago}, to days ago: #{@to_days_ago}}."

      # Kick off the download of one event at a time:
      @event_names.each do |event|
        download event
      end
    end


    # Downloads event data for the named event passed in. Per Mixpanel API documentation,
    # data export responses are newline separated snippets of valid JSON, but the entire
    # response is not actually valid JSON.
    #
    # We will replace the newline characters with a comma, then parse the string as JSON.
    # That will allow us to enumerate through each event row as an element in the larger array.
    #
    # @param  [String] event The name of the event whose data is to be download
    #         from the Mixpanel Data Export service.
    # @return [void]
    def download(event)
      @logger.info '----------------------------------------------------------------'
      @logger.info "Downloading event '#{event}'..."
      data = @service.export(@from_days_ago, @to_days_ago, events: [event])
      process event, data
      @logger.info 'Download complete.'
    end


    # We create a CSV of an event's data, after some intermediary, preparatory processing.
    #
    # Takes the event name passed in and the raw String of Mixpanel export data
    # and parses it up into an Array of Hashes. This is done knowing that Mixpanel
    # export data is a giant String of JSON hashes, separated by newline characters.
    #
    # Once we have this structured data, we figure out what all the keys are, and
    # this determines what header keys we'll use in the CSV that we ask to be created.
    #
    # @param  [String] event The name of the event that we have data for.
    # @param  [String] data The raw String data received as the response from Mixpanel.
    # @return [void]
    def process(event, data)
      if data
        data_array = data.split("\n")
        json_array = data_array.map { |row| JSON.parse(row) }
        # Build a list of header keys from ALL rows of data retrieved, in case some
        # data points had no values for a subset of properties:
        mapped_header_keys = json_array.map do |row|
          if row['properties']
            row['properties'].keys
          else
            @logger.warn "No properties found for event '#{event}' with row information: '#{row}'."
            []
          end
        end

        headers = mapped_header_keys.flatten.uniq
        @logger.info "Retrieved #{data_array.length} records for event '#{event}'."
        create_csv event, json_array, headers unless data_array.empty?
      else
        @logger.info "No data found for event '#{event}'."
      end

    end


    # Performs the actual CSV file creation from the given event, its data and
    # the header keys already identified.
    #
    # @param  [String] event  The name of the event whose data we will create a CSV file for.
    # @param  [Array] data    The array of JSON entries (each, effectively a Hash) containing raw property data.
    #                         It has two elements. The first is the key 'event', which points to the name of the event.
    #                         The second key is called 'properties'. Its value is itself a Hash of key-value pairs
    #                         which represent the actual event property data.
    # @param  [Array] headers The header keys that will also become the CSV file's columns.
    # @return [void]
    def create_csv(event, data, headers)
      file_path = csv_file_path event
      headers.sort!
      @logger.info "Writing CSV file '#{file_path}'..."
      CSV.open(file_path, 'w') do |csv|
        # Write the header row. The first column will be the event itself.
        csv << ['event'] + headers

        # Loop through each data point (event instance recorded).
        data.each do |data_point|
          # Build the iterated entry that will form a single row:
          event_properties = data_point['properties']
          entry = [event] + headers.map do |property_key|
            if property_key == 'time'
              Time.at(event_properties[property_key].to_i).strftime('%Y-%m-%d %H:%M:%S')
            else
              event_properties[property_key].to_s
            end
          end # map

          # Add the entry as a single row to the CSV file:
          csv << entry
        end # each
      end # open
    end # def


    # Provides the full file path we would write a new CSV file to, for the given event.
    # Assumptions
    #   * We are using today as the date that the filename built, will use.
    #   * If we were asked to create date specific subfolders, today's date will also be used for that.
    #
    # @param  [String] event The name of the event for which we are constructing an output file path.
    # @return [String] The full file path that can be written to.
    def csv_file_path(event)
      File.join(csv_directory, csv_filename(event))
    end


    # Builds the CSV filename for the specified event. The name is comprised
    # of the event's name and one or more dates.
    #
    # If @use_event_dates_in_filenames is true, we'll include a date range
    # that represents from 'from' and 'to' date range given.
    #
    # @example
    #   csv_filename('Survey Completed')
    #   # When executed on July 12, 2016, with from_days_ago set to 5 and to_days_ago set to 3,
    #   # this would generate the filename:
    #   # 'SurveyCompleted.2016-07-07.2016-07-09.csv'
    #
    # If however, @use_event_dates_in_filenames is false, we'll just use the
    # date that the script ran as the only date in the file.
    #
    # @example
    #   csv_filename('Survey Completed')
    #   # When executed on July 12, 2016, this will generate the filename:
    #   # 'SurveyCompleted.2016-07-12.csv'
    #
    # @param  [String] event The name of the event we are generating a filename for.
    # @return [String] A filename for writing CSV contents to, minus the full path.
    def csv_filename(event)
      # Are we using the date range of the data being downloaded, as part of the filename?
      if @use_event_dates_in_filenames
        # YES: So we'll retrieve the 'from' and 'to' dates covered.
        now = Date.today
        from_date_segment = (now - @from_days_ago).to_time.strftime('%Y-%m-%d')
        to_date_segment = (now - @to_days_ago).to_time.strftime('%Y-%m-%d')
        "#{event.camelize.remove(' ')}.#{from_date_segment}.#{to_date_segment}.csv"
      else
        # NO: So we'll just use today's date in the filename, which will typically
        # not map to the event data timestamps that will be contained in this file.
        date_segment = Time.now.strftime('%Y-%m-%d')
        "#{event.camelize.remove(' ')}.#{date_segment}.csv"
      end
    end


    # Provides the path where a download performed today, should be placed.
    # Effectively, we take the base {#output_directory} set from our configuration file,
    # and optionally append a path component of the provided date. The decision to include
    # a path component (sub-folder) for the date is determined by @create_subfolders_by_date.
    #
    # Callers can then append a CSV filename to this existing path to have a
    # fully qualified path to write to.
    #
    # @param  [Time] date The timestamp we'll use to extract a date from.
    # @return [String] The base path a filename can be appended to, for writing to today.
    def csv_directory(date = Time.now)
      if @create_subfolders_by_date
        date_segment = date.strftime('%Y-%m-%d')
        path = File.join(@output_directory, date_segment)
      else
        path = @output_directory
      end

      File.expand_path path
    end


    # Creates the CSV directory for the specified date. Does so by calling
    # {#csv_directory} and checking if the path exists. If not, it is created.
    #
    # @param  [Time] date The timestamp we'll use to extract a date from.
    # @return [void]
    def create_csv_directory(date = Time.now)
      path = csv_directory date
      expanded_path = File.expand_path path
      unless File.exist? expanded_path
        FileUtils::mkdir_p expanded_path
      end
    end


    private

    # Sets up our logging instance attribute, with a logger for this class.
    # By default, this class specific logger inherits settings from the root logger.
    # @return [void]
    def configure_logging
      @logger = Logging.logger[self]
    end


    # Sets our {#output_directory} instance attribute by consulting with the
    # {ExporterConfig} class.
    # @return [void]
    def load_configuration
      config = Util::ExporterConfig.new
      @output_directory = config.output_directory
      @from_days_ago = config.from_days_ago
      @to_days_ago = config.to_days_ago
      @create_subfolders_by_date = config.create_subfolders_by_date?
      @use_event_dates_in_filenames = config.use_event_dates_in_filenames?
      @events_to_exclude = config.events_to_exclude || []
      @events_to_include = config.events_to_include || []
    end

  end # class

end # module


# ---------- Development Testing ----------

# exporter = Mixpanel::Exporter.new
# exporter.start
