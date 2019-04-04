# frozen_string_literal: true

module API
  module V2
    module OrderHelpers
      def build_order(attrs)
        (attrs[:side] == 'sell' ? OrderAsk : OrderBid).new \
          state:         ::Order::PENDING,
          member:        current_user,
          ask:           current_market&.base_unit,
          bid:           current_market&.quote_unit,
          market:        current_market,
          ord_type:      attrs[:ord_type] || 'limit',
          price:         attrs[:price],
          volume:        attrs[:volume],
          origin_volume: attrs[:volume]
      end

      def check_balance(order)
        current_user.accounts
                    .find_by_currency_id(order.currency)
                    .balance >= order.locked
      end

      def create_order(attrs)
        create_order_errors = {
          ::Account::AccountError => 'market.account.insufficient_balance',
          ::Order::InsufficientMarketLiquidity => 'market.order.insufficient_market_liquidity',
          ActiveRecord::RecordInvalid => 'market.order.invalid_volume_or_price'
        }

        order = build_order(attrs)
        submit_order(order)
        order
      rescue => e
        message = create_order_errors.fetch(e.class, 'market.order.create_error')
        report_exception_to_screen(e)
        error!({ errors: [message] }, 422)
      end

      def submit_order(order)
        order.fix_number_precision # number must be fixed before computing locked
        order.locked = order.origin_locked = order.compute_locked
        raise ::Account::AccountError unless check_balance(order)

        order.save!

        AMQPQueue.enqueue \
          :order_processor,
          { action: 'submit', order: order.attributes },
          { persistent: false }
      end

      def cancel_order(order)
        AMQPQueue.enqueue(:matching, action: 'cancel', order: order.to_matching_attributes)
      end

      def order_param
        params[:order_by].downcase == 'asc' ? 'id asc' : 'id desc'
      end
    end
  end
end
