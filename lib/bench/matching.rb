require 'rabbitmq/http/client'

# TODO: Add Bench::Error and better errors processing.
# TODO: Add Bench::Report and extract all metrics to it.
# TODO: Add missing frozen_string literal to whole module.
module Bench
  class Matching
    def initialize(config)
      @config = config

      # TODO: Use Faraday instead of RabbitMQ::HTTP::Client.
      @rmq_http_client = ::URI::HTTP.build(
        scheme:   :http,
        host:     ENV.fetch('RABBITMQ_HOST', 'localhost'),
        port:     15672,
        userinfo: "#{ENV.fetch('RABBITMQ_USER', 'guest')}:#{ENV.fetch('RABBITMQ_PASSWORD', 'guest')}"
      ).yield_self { |endpoint| RabbitMQ::HTTP::Client.new(endpoint.to_s) }

      @injector = Injectors.initialize_injector(@config[:orders])
      @currencies = Currency.where(id: @config[:currencies].split(',').map(&:squish).reject(&:blank?))
      # TODO: Print errors in the end of benchmark and include them into report.
      @errors = []
    end

    def run!
      # TODO: Check if Matching daemon is running before start (use queue_info[:consumers]).
      Kernel.puts "Creating members ..."
      @members = Factories.create_list(:member, @config[:traders])

      Kernel.puts "Depositing funds ..."
      @members.map(&method(:become_billionaire))

      Kernel.puts "Generating orders by injector and saving them in db..."
      # TODO: Add orders generation progress bar.
      @injector.generate!(@members)

      @orders_number = @injector.size

      Kernel.puts "Publishing messages to RabbitMQ..."
      @publish_started_at = Time.now
      # TODO: Add orders publishing progress bar.
      publish_messages

      @publish_finished_at = Time.now
      Kernel.puts "Messages are published to RabbitMQ."

      Kernel.puts "Waiting for order processing by matching daemon..."
      wait_for_matching
      @matching_finished_at = Time.now
    end

    def publish_messages
      Array.new(@config[:threads]) do
        Thread.new do
          loop do
            order = @injector.pop
            break unless order
            AMQPQueue.enqueue(:matching, action: 'submit', order: order.to_matching_attributes)
          rescue StandardError => e
            Kernel.puts e
            @errors << e
          end
        end
      end.map(&:join)
    end

    # TODO: Find better solution for getting message number in queue.
    # E.g there is rabbitmqctl list_queues.
    # TODO: Write useful queue info stats into file.
    def wait_for_matching
      loop do
        queue_status = matching_queue_status
        break if queue_status[:messages].zero? &&
                 queue_status[:idle_since].present? &&
                 Time.parse("#{queue_status[:idle_since]} UTC") >= @publish_started_at
        sleep 0.5
      end
    end

    # TODO: Add more useful metrics to result.
    def result
      @result ||=
      begin
        publish_ops =  @orders_number / (@publish_finished_at - @publish_started_at)
        matching_ops =  @orders_number / (@matching_finished_at - @publish_started_at)

        # TODO: Deal with calling iso8601(6) everywhere.
        { config: @config,
          publish_started_at: @publish_started_at.iso8601(6),
          publish_finished_at: @publish_finished_at.iso8601(6),
          matching_started_at: @publish_started_at.iso8601(6),
          matching_finished_at: @matching_finished_at.iso8601(6),
          publish_ops: publish_ops,
          matching_ops: matching_ops }
      end
    end

    def save_report
      report_name = "#{self.class.name.humanize.demodulize}-#{@config[:orders][:injector]}-"\
                    "#{@config[:orders][:number]}-#{Time.now.iso8601}.yml"
      File.open(Rails.root.join(@config[:report_path], report_name), 'w') do |f|
        f.puts YAML.dump(result.deep_stringify_keys)
      end
    end

    private
    # TODO: Use get queue by name.
    # TODO: Use Faraday instead of RabbitMQ::HTTP::Client.
    def matching_queue_status
      @rmq_http_client.list_queues.find { |q| q[:name] == AMQPConfig.binding_queue(:matching).first }
    end

    # TODO: Move to Helpers.
    def become_billionaire(member)
      @currencies.each do |c|
        Factories.create(:deposit, member_id: member.id, currency_id: c.id)
      end
    end
  end
end
