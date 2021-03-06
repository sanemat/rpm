# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'new_relic/control'
module NewRelic
  module Agent
    # This module contains class methods added to support installing custom
    # metric tracers and executing for individual metrics.
    #
    # == Examples
    #
    # When the agent initializes, it extends Module with these methods.
    # However if you want to use the API in code that might get loaded
    # before the agent is initialized you will need to require
    # this file:
    #
    #     require 'new_relic/agent/method_tracer'
    #     class A
    #       include NewRelic::Agent::MethodTracer
    #       def process
    #         ...
    #       end
    #       add_method_tracer :process
    #     end
    #
    # To instrument a class method:
    #
    #     require 'new_relic/agent/method_tracer'
    #     class An
    #       def self.process
    #         ...
    #       end
    #       class << self
    #         include NewRelic::Agent::MethodTracer
    #         add_method_tracer :process
    #       end
    #     end
    #
    # @api public
    #

    module MethodTracer
      def self.included clazz
        clazz.extend ClassMethods
      end

      def self.extended clazz
        clazz.extend ClassMethods
      end

      # Deprecated: original method preserved for API backward compatibility.
      # Use either #trace_execution_scoped or #trace_execution_unscoped
      #
      # @api public
      # @deprecated
      #
      def trace_method_execution(metric_names, push_scope, produce_metric, deduct_call_time_from_parent, &block) #:nodoc:
        if push_scope
          trace_execution_scoped(metric_names, :metric => produce_metric,
                                 :deduct_call_time_from_parent => deduct_call_time_from_parent, &block)
        else
          trace_execution_unscoped(metric_names, &block)
        end
      end

      # Trace a given block with stats assigned to the given metric_name.  It does not
      # provide scoped measurements, meaning whatever is being traced will not 'blame the
      # Controller'--that is to say appear in the breakdown chart.
      # This is code is inlined in #add_method_tracer.
      # * <tt>metric_names</tt> is a single name or an array of names of metrics
      #
      # @api public
      #
      def trace_execution_unscoped(metric_names, options={}) #THREAD_LOCAL_ACCESS
        return yield unless NewRelic::Agent.tl_is_execution_traced?
        t0 = Time.now
        begin
          yield
        ensure
          duration = (Time.now - t0).to_f              # for some reason this is 3 usec faster than Time - Time
          stat_engine.tl_record_unscoped_metrics(metric_names, duration)
        end
      end

      # Deprecated. Use #trace_execution_scoped, a version with an options hash.
      #
      # @deprecated
      #
      def trace_method_execution_with_scope(metric_names, produce_metric, deduct_call_time_from_parent, scoped_metric_only=false, &block) #:nodoc:
        trace_execution_scoped(metric_names,
                               :metric => produce_metric,
                               :deduct_call_time_from_parent => deduct_call_time_from_parent,
                               :scoped_metric_only => scoped_metric_only, &block)
      end

      alias trace_method_execution_no_scope trace_execution_unscoped #:nodoc:

      # Refactored out of the previous trace_execution_scoped
      # method, most methods in this module relate to code used in
      # the #trace_execution_scoped method in this module
      module TraceExecutionScoped
        extend self

        # Shorthand to return the NewRelic::Agent.instance
        def agent_instance
          NewRelic::Agent.instance
        end

        # Shorthand to return the current statistics engine
        def stat_engine
          agent_instance.stats_engine
        end

        # returns a scoped metric stat for the specified name
        def get_stats_scoped(first_name, scoped_metric_only)
          stat_engine.get_stats(first_name, true, scoped_metric_only)
        end

        # Shorthand method to get stats from the stat engine
        def get_stats_unscoped(name)
          stat_engine.get_stats_no_scope(name)
        end

        # Helper for setting a hash key if the hash key is nil,
        # instead of the default ||= behavior which sets if it is
        # false as well
        def set_if_nil(hash, key)
          hash[key] = true if hash[key].nil?
        end

        # helper for logging errors to the newrelic_agent.log
        # properly. Logs the error at error level
        def log_errors(code_area)
          yield
        rescue => e
          ::NewRelic::Agent.logger.error("Caught exception in #{code_area}.", e)
        end

        # provides the header for our traced execution scoped
        # method - gets the initial time, sets the tracing flag if
        # needed, and pushes the frame onto the metric stack
        # logs any errors that occur and returns the start time and
        # the frame so that we can check for it later, to maintain
        # sanity. If the frame stack becomes unbalanced, this
        # transaction loses meaning.
        def trace_execution_scoped_header(state, t0)
          log_errors(:trace_execution_scoped_header) do
            stack = state.traced_method_stack
            stack.push_frame(state, :method_tracer, t0)
          end
        end

        def record_metrics(state, first_name, other_names, duration, exclusive, options)
          # The default value for :scoped_metric is true, so set it as true
          # if it was unset.
          record_scoped_metric = options.has_key?(:scoped_metric) ? options[:scoped_metric] : true

          if options[:metric]
            if record_scoped_metric
              stat_engine.record_scoped_and_unscoped_metrics(state, first_name, other_names, duration, exclusive)
            else
              metrics = [first_name].concat(other_names)
              stat_engine.record_unscoped_metrics(state, metrics, duration, exclusive)
            end
          else
            stat_engine.record_unscoped_metrics(state, other_names, duration, exclusive)
          end
        end

        # Handles the end of the #trace_execution_scoped method -
        # calculating the time taken, popping the tracing flag if
        # needed, deducting time taken by children, and tracing the
        # subsidiary unscoped metrics if any
        #
        # this method fails safely if the header does not manage to
        # push the scope onto the stack - it simply does not trace
        # any metrics.
        def trace_execution_scoped_footer(state, t0, first_name, metric_names, expected_frame, options, t1=Time.now.to_f)
          log_errors(:trace_method_execution_footer) do
            if expected_frame
              stack = state.traced_method_stack
              frame = stack.pop_frame(state, expected_frame, first_name, t1, !!options[:metric])
              duration = t1 - t0
              exclusive = duration - frame.children_time
              record_metrics(state, first_name, metric_names, duration, exclusive, options)
            end
          end
        end
      end
      include TraceExecutionScoped

      # Trace a given block with stats and keep track of the caller.
      # See NewRelic::Agent::MethodTracer::ClassMethods#add_method_tracer for a description of the arguments.
      # +metric_names+ is either a single name or an array of metric names.
      # If more than one metric is passed, the +produce_metric+ option only applies to the first.  The
      # others are always recorded.  Only the first metric is pushed onto the scope stack.
      #
      # Generally you pass an array of metric names if you want to record the metric under additional
      # categories, but generally this *should never ever be done*.  Most of the time you can aggregate
      # on the server.
      #
      # @api public
      #
      def trace_execution_scoped(metric_names, options={}) #THREAD_LOCAL_ACCESS
        state = NewRelic::Agent::TransactionState.tl_get
        return yield unless state.is_execution_traced?

        metric_names = Array(metric_names)
        first_name = metric_names.shift
        return yield if first_name.nil?

        set_if_nil(options, :metric)
        additional_metrics_callback = options[:additional_metrics_callback]
        start_time = Time.now.to_f
        expected_scope = trace_execution_scoped_header(state, start_time)

        begin
          result = yield
          metric_names += Array(additional_metrics_callback.call) if additional_metrics_callback
          result
        ensure
          trace_execution_scoped_footer(state, start_time, first_name, metric_names, expected_scope, options)
        end
      end

      # Defines methods used at the class level, for adding instrumentation
      # @api public
      module ClassMethods
        # contains methods refactored out of the #add_method_tracer method
        module AddMethodTracer
          ALLOWED_KEYS = [:force, :metric, :push_scope, :code_header, :code_footer].freeze

          DEPRECATED_KEYS = [:force, :scoped_metric_only, :deduct_call_time_from_parent].freeze

          # raises an error when the
          # NewRelic::Agent::MethodTracer::ClassMethods#add_method_tracer
          # method is called with improper keys. This aids in
          # debugging new instrumentation by failing fast
          def check_for_illegal_keys!(method_name, options)
            unrecognized_keys = options.keys - ALLOWED_KEYS
            deprecated_keys   = options.keys & DEPRECATED_KEYS

            if unrecognized_keys.any?
              raise "Unrecognized options when adding method tracer to #{method_name}: " +
                    unrecognized_keys.join(', ')
            end

            if deprecated_keys.any?
              NewRelic::Agent.logger.warn("Deprecated options when adding method tracer to #{method_name}: "+
                deprecated_keys.join(', '))
            end
          end

          # validity checking - add_method_tracer must receive either
          # push scope or metric, or else it would record no
          # data. Raises an error if this is the case
          def check_for_push_scope_and_metric(options)
            unless options[:push_scope] || options[:metric]
              raise "Can't add a tracer where push_scope is false and metric is false"
            end
          end

          DEFAULT_SETTINGS = {:push_scope => true, :metric => true, :code_header => "", :code_footer => "" }.freeze

          # Checks the provided options to make sure that they make
          # sense. Raises an error if the options are incorrect to
          # assist with debugging, so that errors occur at class
          # construction time rather than instrumentation run time
          def validate_options(method_name, options)
            unless options.is_a?(Hash)
              raise TypeError.new("Error adding method tracer to #{method_name}: provided options must be a Hash")
            end
            check_for_illegal_keys!(method_name, options)
            options = DEFAULT_SETTINGS.merge(options)
            check_for_push_scope_and_metric(options)
            options
          end

          # Default to the class where the method is defined.
          #
          # Example:
          #  Foo.default_metric_name_code('bar') #=> "Custom/#{Foo.name}/bar"
          def default_metric_name_code(method_name)
            "Custom/#{self.name}/#{method_name.to_s}"
          end

          # Checks to see if the method we are attempting to trace
          # actually exists or not. #add_method_tracer can't do
          # anything if the method doesn't exist.
          def newrelic_method_exists?(method_name)
            exists = method_defined?(method_name) || private_method_defined?(method_name)
            ::NewRelic::Agent.logger.error("Did not trace #{self.name}##{method_name} because that method does not exist") unless exists
            exists
          end

          # Checks to see if we have already traced a method with a
          # given metric by checking to see if the traced method
          # exists. Warns the user if methods are being double-traced
          # to help with debugging custom instrumentation.
          def traced_method_exists?(method_name, metric_name_code)
            exists = method_defined?(_traced_method_name(method_name, metric_name_code))
            ::NewRelic::Agent.logger.error("Attempt to trace a method twice with the same metric: Method = #{method_name}, Metric Name = #{metric_name_code}") if exists
            exists
          end

          # Returns a code snippet to be eval'd that skips tracing
          # when the agent is not tracing execution. turns
          # instrumentation into effectively one method call overhead
          # when the agent is disabled
          def assemble_code_header(method_name, metric_name_code, options)
              header = "return #{_untraced_method_name(method_name, metric_name_code)}(*args, &block) unless NewRelic::Agent.tl_is_execution_traced?\n"

              header += options[:code_header].to_s

              header
          end

          # returns an eval-able string that contains the traced
          # method code used if the agent is not creating a scope for
          # use in scoped metrics.
          def method_without_push_scope(method_name, metric_name_code, options)
            "def #{_traced_method_name(method_name, metric_name_code)}(*args, &block)
              #{assemble_code_header(method_name, metric_name_code, options)}
              t0 = Time.now
              begin
                #{_untraced_method_name(method_name, metric_name_code)}(*args, &block)\n
              ensure
                duration = (Time.now - t0).to_f
                NewRelic::Agent.record_metric(\"#{metric_name_code}\", duration)
                #{options[:code_footer]}
              end
            end"
          end

          # returns an eval-able string that contains the tracing code
          # for a fully traced metric including scoping
          def method_with_push_scope(method_name, metric_name_code, options)
            # At this point, we expect 'self' to point to a Class or Module that
            # has included the NewRelic::Agent::MethodTracer module, which means
            # it should have an instance method defined called
            # 'trace_execution_scoped'.
            #
            # If this is not the case, assume that
            # we're relying on the fact that MethodTracer is included into the
            # Module class by init_plugin, and try to call
            # trace_execution_scoped as a class rather than instance method.
            #
            # The inclusion of MethodTracer into Module will be going away in
            # the future, so if we detect people relying on that behavior, warn
            # and record a supportability metric.
            if self.method_defined?(:trace_execution_scoped)
              klass = 'self'
            else
              NewRelic::Agent.logger.warn("Called add_method_tracer from #{self} without including the NewRelic::Agent::MethodTracer module. This is deprecated and will stop working in the future. Please see http://docs.newrelic.com/docs/ruby/ruby-custom-metric-collection for examples of correct add_method_tracer usage.")
              NewRelic::Agent.increment_metric("Supportability/usage/improper_add_method_tracer")
              klass = 'self.class'
            end
            "def #{_traced_method_name(method_name, metric_name_code)}(*args, &block)
              #{options[:code_header]}
              result = #{klass}.trace_execution_scoped(\"#{metric_name_code}\",
                        :metric => #{options[:metric]}) do
                #{_untraced_method_name(method_name, metric_name_code)}(*args, &block)
              end
              #{options[:code_footer]}
              result
            end"
          end

          # Decides which code snippet we should be eval'ing in this
          # context, based on the options.
          def code_to_eval(method_name, metric_name_code, options)
            options = validate_options(method_name, options)
            if options[:push_scope]
              method_with_push_scope(method_name, metric_name_code, options)
            else
              method_without_push_scope(method_name, metric_name_code, options)
            end
          end
        end
        include AddMethodTracer



        # Add a method tracer to the specified method.
        #
        # === Options
        #
        # * <tt>:push_scope => false</tt> specifies this method tracer should not
        #   keep track of the caller; it will not show up in controller breakdown
        #   pie charts.
        # * <tt>:metric => false</tt> specifies that no metric will be recorded.
        #   Instead the call will show up in transaction traces as well as traces
        #   shown in Developer Mode.
        #
        # === Uncommon Options
        #
        # * <tt>:code_header</tt> and <tt>:code_footer</tt> specify ruby code that
        #   is inserted into the tracer before and after the call.
        #
        # === Overriding the metric name
        #
        # +metric_name_code+ is a string that is eval'd to get the
        # name of the metric associated with the call, so if you want to
        # use interpolaion evaluated at call time, then single quote
        # the value like this:
        #
        #     add_method_tracer :foo, 'Custom/#{self.class.name}/foo'
        #
        # This would name the metric according to the class of the runtime
        # intance, as opposed to the class where +foo+ is defined.
        #
        # If not provided, the metric name will be <tt>Custom/ClassName/method_name</tt>.
        #
        # === Examples
        #
        # Instrument +foo+ only for custom views--will not show up in transaction traces or caller breakdown graphs:
        #
        #     add_method_tracer :foo, :push_scope => false
        #
        # Instrument +foo+ just for transaction traces only:
        #
        #     add_method_tracer :foo, :metric => false
        #
        # Instrument +foo+ so it shows up in transaction traces and caller breakdown graphs
        # for actions:
        #
        #     add_method_tracer :foo
        #
        # which is equivalent to:
        #
        #     add_method_tracer :foo, 'Custom/#{self.class.name}/foo', :push_scope => true, :metric => true
        #
        # Instrument the class method +foo+ with the metric name 'Custom/People/fetch':
        #
        #     class << self
        #       add_method_tracer :foo, 'Custom/People/fetch'
        #     end
        #
        # @api public
        #
        def add_method_tracer(method_name, metric_name_code=nil, options = {})
          return unless newrelic_method_exists?(method_name)
          metric_name_code ||= default_metric_name_code(method_name)
          return if traced_method_exists?(method_name, metric_name_code)

          traced_method = code_to_eval(method_name, metric_name_code, options)

          visibility = NewRelic::Helper.instance_method_visibility self, method_name

          class_eval traced_method, __FILE__, __LINE__
          alias_method _untraced_method_name(method_name, metric_name_code), method_name
          alias_method method_name, _traced_method_name(method_name, metric_name_code)
          send visibility, method_name
          send visibility, _traced_method_name(method_name, metric_name_code)
          ::NewRelic::Agent.logger.debug("Traced method: class = #{self.name},"+
                    "method = #{method_name}, "+
                    "metric = '#{metric_name_code}'")
        end

        # For tests only because tracers must be removed in reverse-order
        # from when they were added, or else other tracers that were added to the same method
        # may get removed as well.
        def remove_method_tracer(method_name, metric_name_code) # :nodoc:
          return unless Agent.config[:agent_enabled]
          if method_defined? "#{_traced_method_name(method_name, metric_name_code)}"
            alias_method method_name, "#{_untraced_method_name(method_name, metric_name_code)}"
            undef_method "#{_traced_method_name(method_name, metric_name_code)}"
            ::NewRelic::Agent.logger.debug("removed method tracer #{method_name} #{metric_name_code}\n")
          else
            raise "No tracer for '#{metric_name_code}' on method '#{method_name}'"
          end
        end
        private

        # given a method and a metric, this method returns the
        # untraced alias of the method name
        def _untraced_method_name(method_name, metric_name)
          "#{_sanitize_name(method_name)}_without_trace_#{_sanitize_name(metric_name)}"
        end

        # given a method and a metric, this method returns the traced
        # alias of the method name
        def _traced_method_name(method_name, metric_name)
          "#{_sanitize_name(method_name)}_with_trace_#{_sanitize_name(metric_name)}"
        end

        # makes sure that method names do not contain characters that
        # might break the interpreter, for example ! or ? characters
        # that are not allowed in the middle of method names
        def _sanitize_name(name)
          name.to_s.tr_s('^a-zA-Z0-9', '_')
        end
      end

      # @!parse extend ClassMethods
    end
  end
end
