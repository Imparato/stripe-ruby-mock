module StripeMock
  module RequestHandlers
    module Invoices

      def Invoices.included(klass)
        klass.add_handler 'post /v1/invoices',               :new_invoice
        klass.add_handler 'get /v1/invoices/upcoming',       :upcoming_invoice
        klass.add_handler 'get /v1/invoices/(.*)/lines',     :get_invoice_line_items
        klass.add_handler 'get /v1/invoices/(.*)',           :get_invoice
        klass.add_handler 'get /v1/invoices',                :list_invoices
        klass.add_handler 'post /v1/invoices/(.*)/pay',      :pay_invoice
        klass.add_handler 'post /v1/invoices/(.*)/finalize', :finalize_invoice
        klass.add_handler 'post /v1/invoices/(.*)',          :update_invoice
        klass.add_handler 'delete /v1/invoices/([^/]*)',     :delete_invoice
      end

      def new_invoice(route, method_url, params, headers)
        id = new_id('in')

        # params[:customer] is ensured to be an id
        validate_create_invoice_params(params)

        # If not subscription set, the created invoice will include all pending invoice items for the customer
        unless params.key?(:subscription)
          pending_items = invoice_items.values.select { |ii|
            ii_customer_id = ii[:customer].is_a?(Stripe::Customer) ? ii[:customer][:id] : ii[:customer]
            ii_customer_id == params[:customer]
          }

          raise Stripe::InvalidRequestError.new("Nothing to invoice for customer", http_status: 400) if pending_items.empty?

          line_items = pending_items.map { |ii|
            ii[:invoice] = id
            amount = ii[:price] ? ii[:price][:unit_amount] : ii[:amount]
            Data.mock_line_item(id: new_id('il'), invoice_item: ii[:id], amount: amount, price: ii[:price])
          }
        end

        invoices[id] = Data.mock_invoice(line_items, params.merge(:id => id, :status => "draft"))
      end

      def update_invoice(route, method_url, params, headers)
        route =~ method_url
        params.delete(:lines) if params[:lines]
        assert_existence :invoice, $1, invoices[$1]
        invoices[$1].merge!(params)
      end

      def list_invoices(route, method_url, params, headers)
        params[:offset] ||= 0
        params[:limit] ||= 10

        Data.mock_list_object(invoices.values, params.merge(filterable_by: %w[customer status subscription]))
      end

      def get_invoice(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]
      end

      def get_invoice_line_items(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]
        invoices[$1][:lines]
      end

      def pay_invoice(route, method_url, params, headers)
        route =~ method_url
        invoice = assert_existence :invoice, $1, invoices[$1]
        charge = invoice_charge(invoices[$1])

        invoices[$1].merge!(invoice_pay_attributes(invoice, charge))
      end

      def finalize_invoice(route, method_url, params, headers)
        route =~ method_url
        invoice = assert_existence :invoice, $1, invoices[$1]

        payment_intent_params = { amount: invoice[:amount_due], currency: invoice[:currency], invoice: invoice[:id] }
        merge_params = {
          status: "open",
          payment_intent: new_payment_intent("", "", payment_intent_params, {})[:id],
          status_transitions: invoice[:status_transitions].merge(finalized_at: Time.now.to_i)
        }

        invoices[$1].merge!(merge_params)
      end

      def upcoming_invoice(route, method_url, params, headers)
        route =~ method_url
        raise Stripe::InvalidRequestError.new('Missing required param: customer', nil, http_status: 400) if params[:customer].nil?
        raise Stripe::InvalidRequestError.new('When previewing changes to a subscription, you must specify either `subscription` or `subscription_items`', nil, http_status: 400) if !params[:subscription_proration_date].nil? && params[:subscription].nil? && params[:subscription_plan].nil?
        raise Stripe::InvalidRequestError.new('Cannot specify proration date without specifying a subscription', nil, http_status: 400) if !params[:subscription_proration_date].nil? && params[:subscription].nil?

        customer = customers[params[:customer]]
        assert_existence :customer, params[:customer], customer

        raise Stripe::InvalidRequestError.new("No upcoming invoices for customer: #{customer[:id]}", nil, http_status: 404) if customer[:subscriptions][:data].length == 0

        subscription =
          if params[:subscription]
            customer[:subscriptions][:data].select{|s|s[:id] == params[:subscription]}.first
          else
            customer[:subscriptions][:data].min_by { |sub| sub[:current_period_end] }
          end

        if params[:subscription_proration_date] && !((subscription[:current_period_start]..subscription[:current_period_end]) === params[:subscription_proration_date])
          raise Stripe::InvalidRequestError.new('Cannot specify proration date outside of current subscription period', nil, http_status: 400)
        end

        prorating = false
        subscription_proration_date = nil
        subscription_plan_id = params[:subscription_plan] || subscription[:plan][:id]
        subscription_quantity = params[:subscription_quantity] || subscription[:quantity]
        if subscription_plan_id != subscription[:plan][:id] || subscription_quantity != subscription[:quantity]
          prorating = true
          invoice_date = Time.now.to_i
          subscription_plan = assert_existence :plan, subscription_plan_id, plans[subscription_plan_id.to_s]
          preview_subscription = Data.mock_subscription
          preview_subscription = resolve_subscription_changes(preview_subscription, [subscription_plan], customer, { trial_end: params[:subscription_trial_end] })
          preview_subscription[:id] = subscription[:id]
          preview_subscription[:quantity] = subscription_quantity
          subscription_proration_date = params[:subscription_proration_date] || Time.now
        else
          preview_subscription = subscription
          invoice_date = subscription[:current_period_end]
        end

        invoice_lines = []

        if prorating
          unused_amount = (
            subscription[:plan][:amount].to_f *
              subscription[:quantity] *
              (subscription[:current_period_end] - subscription_proration_date.to_i) / (subscription[:current_period_end] - subscription[:current_period_start])
            ).ceil

          invoice_lines << Data.mock_line_item(
                                   id: new_id('ii'),
                                   amount: -unused_amount,
                                   description: 'Unused time',
                                   plan: subscription[:plan],
                                   period: {
                                       start: subscription_proration_date.to_i,
                                       end: subscription[:current_period_end]
                                   },
                                   quantity: subscription[:quantity],
                                   proration: true
          )

          preview_plan = assert_existence :plan, params[:subscription_plan], plans[params[:subscription_plan]]
          if preview_plan[:interval] == subscription[:plan][:interval] && preview_plan[:interval_count] == subscription[:plan][:interval_count] && params[:subscription_trial_end].nil?
            remaining_amount = preview_plan[:amount] * subscription_quantity * (subscription[:current_period_end] - subscription_proration_date.to_i) / (subscription[:current_period_end] - subscription[:current_period_start])
            invoice_lines << Data.mock_line_item(
                                     id: new_id('ii'),
                                     amount: remaining_amount,
                                     description: 'Remaining time',
                                     plan: preview_plan,
                                     period: {
                                         start: subscription_proration_date.to_i,
                                         end: subscription[:current_period_end]
                                     },
                                     quantity: subscription_quantity,
                                     proration: true
            )
          end
        end

        subscription_line = get_mock_subscription_line_item(preview_subscription)
        invoice_lines << subscription_line

        Data.mock_invoice(invoice_lines,
          id: new_id('in'),
          customer: customer[:id],
          discount: customer[:discount],
          created: invoice_date,
          starting_balance: customer[:account_balance],
          subscription: preview_subscription[:id],
          period_start: prorating ? invoice_date : preview_subscription[:current_period_start],
          period_end: prorating ? invoice_date : preview_subscription[:current_period_end],
          next_payment_attempt: preview_subscription[:current_period_end] + 3600 )
      end

      def invoice_pay_attributes(invoice, charge)
        {
          paid: true,
          attempted: true,
          charge: charge[:id],
          status: "paid",
          amount_paid: invoice[:amount_due],
          amount_due:  0,
          status_transitions: invoice[:status_transitions].merge(paid_at: Time.now.to_i),
        }
      end

      def delete_invoice(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]

        invoice = invoices[$1]

        unless invoice[:subscription].nil?
          raise Stripe::InvalidRequestError.new("You can't delete invoices created by subscriptions", 'invoice', http_status: 400)
        end

        unless invoice[:status] == "draft"
          raise Stripe::InvalidRequestError.new("You can only delete draft invoices", 'invoice', http_status: 400)
        end

        invoices[$1] = {
          id: invoice[:id],
          deleted: true
        }
      end

      private

      def get_mock_subscription_line_item(subscription)
        Data.mock_line_item(
          id: subscription[:id],
          type: "subscription",
          plan: subscription[:plan],
          amount: subscription[:status] == 'trialing' ? 0 : subscription[:plan][:amount] * subscription[:quantity],
          discountable: true,
          quantity: subscription[:quantity],
          period: {
            start: subscription[:current_period_end],
            end: get_ending_time(subscription[:current_period_start], subscription[:plan], 2)
          })
      end

      ## charge the customer on the invoice, if one does not exist, create
      #anonymous charge
      def invoice_charge(invoice)
        begin
          new_charge(nil, nil, {customer: invoice[:customer], amount: invoice[:amount_due], currency: StripeMock.default_currency}, nil)
        rescue Stripe::InvalidRequestError
          new_charge(nil, nil, {source: generate_card_token, amount: invoice[:amount_due], currency: StripeMock.default_currency}, nil)
        end
      end

    end
  end
end
