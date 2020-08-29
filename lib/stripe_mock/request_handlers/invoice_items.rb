module StripeMock
  module RequestHandlers
    module InvoiceItems

      def InvoiceItems.included(klass)
        klass.add_handler 'post /v1/invoiceitems',        :new_invoice_item
        klass.add_handler 'post /v1/invoiceitems/(.*)',   :update_invoice_item
        klass.add_handler 'get /v1/invoiceitems/(.*)',    :get_invoice_item
        klass.add_handler 'get /v1/invoiceitems',         :list_invoice_items
        klass.add_handler 'delete /v1/invoiceitems/(.*)', :delete_invoice_item
      end

      def new_invoice_item(route, method_url, params, headers)
        params[:id] ||= new_id('ii')

        item = Data.mock_invoice_item(params)
        inject_price_object(item)
        compute_amount(item)
        invoice_items[params[:id]] = item
      end

      def update_invoice_item(route, method_url, params, headers)
        route =~ method_url
        item = assert_existence :list_item, $1, invoice_items[$1]
        item.merge!(params)
        inject_price_object(item)
        compute_amount(item)
      end

      def delete_invoice_item(route, method_url, params, headers)
        route =~ method_url
        assert_existence :list_item, $1, invoice_items[$1]

        invoice_items[$1] = {
          id: invoice_items[$1][:id],
          deleted: true
        }
      end

      def list_invoice_items(route, method_url, params, headers)
        items = invoice_items.values
        items.each do |item|
          inject_price_object(item)
        end

        Data.mock_list_object(items, params)
      end

      def get_invoice_item(route, method_url, params, headers)
        route =~ method_url
        item = assert_existence :invoice_item, $1, invoice_items[$1]

        inject_price_object(item)
      end

      private

      def inject_price_object(item)
        return item if item[:price].nil?
        return item unless item[:price].is_a?(String)

        price = assert_existence :price, item[:price], prices[item[:price]]
        item[:price] = price

        item
      end

      def compute_amount(item)
        return item if item[:price].nil?

        item[:amount] = item[:price][:amount]

        item
      end
    end
  end
end
