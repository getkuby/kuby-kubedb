require 'helm-rb'
require 'kuby'

module Kuby
  module KubeDB
    class KubeDBError < StandardError; end
    class OperatorDeployError < KubeDBError; end

    class Plugin < ::Kuby::Kubernetes::Plugin
      NAMESPACE = 'kube-system'.freeze
      REPO_NAME = 'appscode'.freeze
      REPO_URL = 'https://charts.appscode.com/stable/'.freeze
      OPERATOR_DEPLOYMENT_NAME = 'kubedb-operator'.freeze
      OPERATOR_RELEASE_NAME = 'kubedb-operator'.freeze
      CATALOG_RELEASE_NAME = 'kubedb-catalog'.freeze
      OPERATOR_CHART_NAME = 'appscode/kubedb'.freeze
      CATALOG_CHART_NAME = 'appscode/kubedb-catalog'.freeze
      OPERATOR_WAIT_INTERVAL = 5  # seconds
      OPERATOR_WAIT_MAX = 30      # seconds

      OPERATOR_PARAMS = {
        'apiserver.enableValidatingWebhook' => 'true',
        'apiserver.enableMutatingWebhook'   => 'true'
      }

      OPERATOR_PARAMS.freeze

      def setup
        Kuby.logger.info(ColorizedString['Setting up kubedb'].yellow)

        Kuby.logger.info(ColorizedString['Fetching Helm chart'].yellow)
        helm_cli.add_repo(REPO_NAME, REPO_URL)
        helm_cli.update_repos

        Kuby.logger.info(ColorizedString['Deploying kubedb operator'].yellow)
        operator_deployed? ? upgrade_operator : install_operator

        wait_for_operator do
          Kuby.logger.info(ColorizedString['Waiting for kubedb operator deployment'].yellow)
        end

        Kuby.logger.info(ColorizedString['Deploying kubedb catalog'].yellow)
        catalog_deployed? ? upgrade_catalog : install_catalog

        Kuby.logger.info(ColorizedString['Kubedb setup finished'].yellow)
      end

      private

      def install_operator
        helm_cli.install_chart(OPERATOR_CHART_NAME, {
          release: OPERATOR_RELEASE_NAME,
          version: Kuby::KubeDB::KUBEDB_VERSION,
          namespace: NAMESPACE,
          params: OPERATOR_PARAMS
        })
      end

      def upgrade_operator
        helm_cli.upgrade_chart(OPERATOR_CHART_NAME, {
          release: OPERATOR_RELEASE_NAME,
          version: Kuby::KubeDB::KUBEDB_VERSION,
          namespace: NAMESPACE,
          params: OPERATOR_PARAMS
        })
      end

      def install_catalog
        helm_cli.install_chart(CATALOG_CHART_NAME, {
          release: CATALOG_RELEASE_NAME,
          version: Kuby::KubeDB::KUBEDB_VERSION,
          namespace: NAMESPACE
        })
      end

      def upgrade_catalog
        helm_cli.upgrade_chart(CATALOG_CHART_NAME, {
          release: CATALOG_RELEASE_NAME,
          version: Kuby::KubeDB::KUBEDB_VERSION,
          namespace: NAMESPACE
        })
      end

      def wait_for_operator
        time_elapsed = 0

        loop do
          break if operator_ready?

          if time_elapsed >= OPERATOR_WAIT_MAX
            raise OperatorDeployError, 'timeout waiting for operator to start. '\
              "Waited #{time_elapsed}s."
          end

          yield

          sleep OPERATOR_WAIT_INTERVAL
          time_elapsed += OPERATOR_WAIT_INTERVAL
        end
      end

      def operator_ready?
        depl = operator_deployment
        rs = find_operator_rs(depl)
        return false unless depl && rs

        observed_generation = depl.dig('status', 'observedGeneration')
        current_generation = depl.dig('metadata', 'generation')
        return false unless observed_generation == current_generation

        rollout_data = { 'replicas' => 0 }.merge(
          depl['status'].slice(
            *%w(replicas updatedReplicas availableReplicas unavailableReplicas)
          )
        )

        desired_replicas = depl['spec']['replicas'].to_i
        rs_desired_replicas = rs['spec']['replicas'].to_i

        rs_ready?(rs) &&
          rs_desired_replicas == desired_replicas &&
          rollout_data['updatedReplicas'].to_i == desired_replicas &&
          rollout_data['updatedReplicas'].to_i == rollout_data['availableReplicas'].to_i
      end

      def rs_ready?(rs)
        observed_generation = rs.dig('status', 'observedGeneration')
        current_generation = rs.dig('metadata', 'generation')
        return false if observed_generation != current_generation

        rollout_data = { "replicas" => 0 }.merge(
          rs['status'].slice('replicas', 'availableReplicas', 'readyReplicas')
        )

        desired_replicas = rs['spec']['replicas'].to_i
        desired_replicas == rollout_data['availableReplicas'].to_i &&
          desired_replicas == rollout_data['readyReplicas'].to_i
      end

      def operator_deployment
        kubernetes_cli.get_object(
          'Deployment', NAMESPACE, OPERATOR_DEPLOYMENT_NAME
        )
      rescue ::Kuby::Kubernetes::GetResourceError
        nil
      end

      def find_operator_rs(depl)
        match_labels = depl.dig('metadata', 'labels')
        all_rs_data = kubernetes_cli.get_objects('ReplicaSet', NAMESPACE, match_labels)
        current_revision = depl.dig('metadata', 'annotations', 'deployment.kubernetes.io/revision')

        all_rs_data.find do |rs|
          rs.dig('metadata', 'ownerReferences').any? { |ref| ref['uid'] == depl.dig('metadata', 'uid') } &&
            rs.dig('metadata', 'annotations', 'deployment.kubernetes.io/revision') == current_revision
        end
      rescue ::Kuby::Kubernetes::GetResourceError
        nil
      end

      def operator_deployed?
        helm_cli.release_exists?(OPERATOR_RELEASE_NAME, namespace: NAMESPACE)
      end

      def catalog_deployed?
        helm_cli.release_exists?(CATALOG_RELEASE_NAME, namespace: NAMESPACE)
      end

      def helm_cli
        @helm_cli ||= HelmRb::CLI.new(provider.kubeconfig_path)
      end

      def kubernetes_cli
        provider.kubernetes_cli
      end

      def provider
        definition.kubernetes.provider
      end
    end
  end
end