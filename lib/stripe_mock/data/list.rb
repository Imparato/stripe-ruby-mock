module StripeMock
  module Data
    class List
      attr_reader :data, :limit, :offset, :starting_after, :ending_before, :active, :include_total_count, :filter_by

      def initialize(data, options = {})
        @data = Array(data.clone)
        @limit = [[options[:limit] || 10, 100].min, 1].max # restrict @limit to 1..100
        @starting_after = options[:starting_after]
        @ending_before  = options[:ending_before]
        @active = options[:active]
        if @data.first.is_a?(Hash) && @data.first[:created]
          @data.sort_by! { |x| x[:created] }
          @data.reverse!
        elsif @data.first.respond_to?(:created)
          @data.sort_by { |x| x.created }
          @data.reverse!
        end

        @include_total_count = options[:"include[]"] && options[:"include[]"].include?("total_count")

        # Each object type can construct the list with an array of filterable attributes
        # under "filterable_by" option.
        @filter_by = options.slice(*(options[:filterable_by] || []).map(&:to_sym))
      end

      def url
        "/v1/#{object_types}"
      end

      def to_hash
        { object: "list", data: data_page, url: url, has_more: has_more? }.tap { |h|
          h[:total_count] = data.size if include_total_count
        }
      end
      alias_method :to_h, :to_hash

      def has_more?
        (offset + limit) < data.size
      end

      def method_missing(method_name, *args, &block)
        hash = to_hash

        if hash.keys.include?(method_name)
          hash[method_name]
        else
          super
        end
      end

      def respond_to?(method_name, priv = false)
        to_hash.keys.include?(method_name) || super
      end

      private

      def offset
        case
        when starting_after
          index = data.index { |datum| datum[:id] == starting_after }
          (index || raise("No such object id: #{starting_after}")) + 1
        when ending_before
          index = data.index { |datum| datum[:id] == ending_before }
          (index || raise("No such object id: #{ending_before}")) - 1
        else
          0
        end
      end

      def data_page
        filtered_data[offset, limit]
      end

      def filtered_data
        filtered_data = data
        filtered_data = filtered_data.select { |d| d[:active] == active } unless active.nil?
        filter_by.each do |key, value|
          filtered_data.select! do |d|
            next true if d[key] == value

            # comparison is made with ids (string), stripe hash (mocks) representations
            # or a Stripe object which also respond to []
            data_id = d[key].is_a?(String) ? d[key] : d[key][:id]
            value_id = value.is_a?(String) ? value : value[:id]

            data_id == value_id
          end
        end

        filtered_data
      end

      def object_types
        first_object = data[0]
        return unless first_object

        if first_object.is_a?(Hash) && first_object.key?(:object)
          "#{first_object[:object]}s"
        else
          "#{first_object.class.to_s.split('::')[-1].downcase}s"
        end
      end
    end
  end
end
