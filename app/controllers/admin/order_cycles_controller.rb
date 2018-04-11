require 'open_food_network/permissions'
require 'open_food_network/order_cycle_form_applicator'
require 'open_food_network/proxy_order_syncer'

module Admin
  class OrderCyclesController < ResourceController
    include OrderCyclesHelper

    prepend_before_filter :load_data_for_index, :only => :index
    before_filter :require_coordinator, only: :new
    before_filter :remove_protected_attrs, only: [:update]
    before_filter :check_editable_schedule_ids, only: [:create, :update]
    before_filter :require_order_cycle_set_params, only: [:bulk_update]
    around_filter :protect_invalid_destroy, only: :destroy
    create.after :sync_subscriptions
    update.after :sync_subscriptions

    def index
      respond_to do |format|
        format.html
        format.json do
          render_as_json @collection, ams_prefix: params[:ams_prefix], current_user: spree_current_user
        end
      end
    end

    def show
      respond_to do |format|
        format.html
        format.json do
          render_as_json @order_cycle, current_user: spree_current_user
        end
      end
    end

    def new
      respond_to do |format|
        format.html
        format.json do
          render_as_json @order_cycle, current_user: spree_current_user
        end
      end
    end

    def create
      @order_cycle = OrderCycle.new(params[:order_cycle])

      respond_to do |format|
        if @order_cycle.save
          OpenFoodNetwork::OrderCycleFormApplicator.new(@order_cycle, spree_current_user).go!
          invoke_callbacks(:create, :after)
          flash[:notice] = I18n.t(:order_cycles_create_notice)
          format.html { redirect_to admin_order_cycles_path }
          format.json { render :json => { success: true } }
        else
          format.html
          format.json { render :json => { errors: @order_cycle.errors.full_messages }, status: :unprocessable_entity }
        end
      end
    end

    def update
      @order_cycle = OrderCycle.find params[:id]

      respond_to do |format|
        if @order_cycle.update_attributes(params[:order_cycle])
          unless params[:order_cycle][:incoming_exchanges].nil? && params[:order_cycle][:outgoing_exchanges].nil?
            # Only update apply exchange information if it is actually submmitted
            OpenFoodNetwork::OrderCycleFormApplicator.new(@order_cycle, spree_current_user).go!
          end
          invoke_callbacks(:update, :after)
          flash[:notice] = I18n.t(:order_cycles_update_notice) if params[:reloading] == '1'
          format.html { redirect_to main_app.edit_admin_order_cycle_path(@order_cycle) }
          format.json { render :json => { :success => true } }
        else
          format.json { render :json => { errors: @order_cycle.errors.full_messages }, status: :unprocessable_entity }
        end
      end
    end

    def bulk_update
      if order_cycle_set.andand.save
        respond_to do |format|
          format.json { render_as_json @order_cycles, ams_prefix: 'index', current_user: spree_current_user }
        end
      else
        respond_to do |format|
          order_cycle = order_cycle_set.collection.find{ |oc| oc.errors.present? }
          format.json { render :json => { errors: order_cycle.errors.full_messages }, status: :unprocessable_entity }
        end
      end
    end

    def clone
      @order_cycle = OrderCycle.find params[:id]
      @order_cycle.clone!
      redirect_to main_app.admin_order_cycles_path, notice: I18n.t(:order_cycles_clone_notice, name: @order_cycle.name)
    end

    # Send notifications to all producers who are part of the order cycle
    def notify_producers
      Delayed::Job.enqueue OrderCycleNotificationJob.new(params[:id].to_i)

      redirect_to main_app.admin_order_cycles_path, notice: I18n.t(:order_cycles_email_to_producers_notice)
    end


    protected
    def collection
      return Enterprise.where("1=0") unless json_request?
      return order_cycles_from_set if params[:order_cycle_set]
      ocs = if params[:as] == "distributor"
        OrderCycle.preload(:schedules).ransack(params[:q]).result.
          involving_managed_distributors_of(spree_current_user).order('updated_at DESC')
      elsif params[:as] == "producer"
        OrderCycle.preload(:schedules).ransack(params[:q]).result.
          involving_managed_producers_of(spree_current_user).order('updated_at DESC')
      else
        OrderCycle.preload(:schedules).ransack(params[:q]).result.accessible_by(spree_current_user)
      end

      ocs.undated |
        ocs.soonest_closing |
        ocs.soonest_opening |
        ocs.closed
    end

    def collection_actions
      [:index, :bulk_update]
    end

    private
    def load_data_for_index
      if json_request?
        # Split ransack params into all those that currently exist and new ones to limit returned ocs to recent or undated
        orders_close_at_gt = params[:q].andand.delete(:orders_close_at_gt) || 31.days.ago
        params[:q] = {
          g: [ params.delete(:q) || {}, { m: 'or', orders_close_at_gt: orders_close_at_gt, orders_close_at_null: true } ]
        }
        @collection = collection
      end
    end

    def require_coordinator
      if params[:coordinator_id] && @order_cycle.coordinator = permitted_coordinating_enterprises_for(@order_cycle).find_by_id(params[:coordinator_id])
        return
      end

      available_coordinators = permitted_coordinating_enterprises_for(@order_cycle)
      case available_coordinators.count
      when 0
        flash[:error] = I18n.t(:order_cycles_no_permission_to_coordinate_error)
        redirect_to main_app.admin_order_cycles_path
      when 1
        @order_cycle.coordinator = available_coordinators.first
      else
        flash[:error] = I18n.t(:order_cycles_no_permission_to_create_error) if params[:coordinator_id]
        render :set_coordinator
      end
    end

    def protect_invalid_destroy
      # Can't delete if OC is linked to any orders or schedules
      if @order_cycle.schedules.any?
        redirect_to main_app.admin_order_cycles_url
        flash[:error] = I18n.t('admin.order_cycles.destroy_errors.schedule_present')
      else
        begin
          yield
        rescue ActiveRecord::InvalidForeignKey
          redirect_to main_app.admin_order_cycles_url
          flash[:error] = I18n.t('admin.order_cycles.destroy_errors.orders_present')
        end
      end
    end

    def remove_protected_attrs
      params[:order_cycle].delete :coordinator_id

      unless Enterprise.managed_by(spree_current_user).include?(@order_cycle.coordinator)
        params[:order_cycle].delete_if{ |k,v| [:name, :orders_open_at, :orders_close_at].include? k.to_sym }
      end
    end

    def remove_unauthorized_bulk_attrs
      params[:order_cycle_set][:collection_attributes].each do |i, hash|
        order_cycle = OrderCycle.find(hash[:id])
        unless Enterprise.managed_by(spree_current_user).include?(order_cycle.andand.coordinator)
          params[:order_cycle_set][:collection_attributes].delete i
        end
      end
    end

    def check_editable_schedule_ids
      return unless params[:order_cycle][:schedule_ids]
      requested = params[:order_cycle][:schedule_ids].map(&:to_i)
      @existing_schedule_ids = @order_cycle.persisted? ? @order_cycle.schedule_ids : []
      permitted = Schedule.where(id: requested | @existing_schedule_ids).merge(OpenFoodNetwork::Permissions.new(spree_current_user).editable_schedules).pluck(:id)
      result = @existing_schedule_ids
      result |= (requested & permitted) # add any requested & permitted ids
      result -= ((result & permitted) - requested) # remove any existing and permitted ids that were not specifically requested
      params[:order_cycle][:schedule_ids] = result
    end

    def sync_subscriptions
      return unless params[:order_cycle][:schedule_ids]
      removed_ids = @existing_schedule_ids - @order_cycle.schedule_ids
      new_ids = @order_cycle.schedule_ids - @existing_schedule_ids
      if removed_ids.any? || new_ids.any?
        schedules = Schedule.where(id: removed_ids + new_ids)
        subscriptions = Subscription.where(schedule_id: schedules)
        syncer = OpenFoodNetwork::ProxyOrderSyncer.new(subscriptions)
        syncer.sync!
      end
    end

    def order_cycles_from_set
      remove_unauthorized_bulk_attrs
      OrderCycle.where(id: params[:order_cycle_set][:collection_attributes].map{ |k,v| v[:id] })
    end

    def order_cycle_set
      @order_cycle_set ||= OrderCycleSet.new(@order_cycles, params[:order_cycle_set])
    end

    def require_order_cycle_set_params
      return if params[:order_cycle_set]
      render json: { errors: t('admin.order_cycles.bulk_update.no_data') }, status: :unprocessable_entity
    end

    def ams_prefix_whitelist
      [:basic, :index]
    end
  end
end
