// Jenkins Job DSL — creates the pgaas-deploy pipeline job
// Apply via: seed job or Jenkins Script Console

pipelineJob('pgaas-deploy') {
    description('Deploy PGaaS platform + user configs to a Kubernetes cluster')

    parameters {
        stringParam('PGAAS_VERSION', '', 'Platform artifact version (e.g., 1.2.3)')
        stringParam('USERS_VERSION', '', 'Users config artifact version')
        stringParam('INS', '', 'Client INS code(s), comma-separated (e.g., ic1 or ic1,is1)')
        choiceParam('ENV', ['perf', 'pprod', 'prod'], 'Target environment')
        stringParam('ENV_OVERRIDE', '', 'HP sub-env override (e.g., dev1, pic). If set, overrides ENV choice')
        stringParam('DC', '', 'Datacenter (e.g., dc1). Empty = client default')
        choiceParam('ACTION', ['create', 'upgrade'], 'Deployment action')
        stringParam('KUBECONFIG_CRED', '', 'Jenkins credential ID for kubeconfig file')
    }

    definition {
        cps {
            sandbox(true)
            script('''
pipeline {
    agent any

    environment {
        VAULT_ADDR      = "${env.VAULT_ADDR}"
        ARTIFACTORY_URL = "${env.ARTIFACTORY_URL}"
    }

    stages {
        stage('Validate Parameters') {
            steps {
                script {
                    def errors = []
                    if (!params.PGAAS_VERSION?.trim()) errors << 'PGAAS_VERSION is required'
                    if (!params.USERS_VERSION?.trim()) errors << 'USERS_VERSION is required'
                    if (!params.INS?.trim()) errors << 'INS is required'
                    if (!params.KUBECONFIG_CRED?.trim()) errors << 'KUBECONFIG_CRED is required'
                    if (errors) {
                        error("Parameter validation failed:\\n" + errors.join('\\n'))
                    }

                    env.EFFECTIVE_ENV = params.ENV_OVERRIDE?.trim() ? params.ENV_OVERRIDE.trim() : params.ENV
                    echo "Effective environment: ${env.EFFECTIVE_ENV}"
                }
            }
        }

        stage('Fetch Artifacts') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'APPROLE_CRED',
                    usernameVariable: 'ROLE_ID',
                    passwordVariable: 'SECRET_ID'
                )]) {
                    sh """
                        set -euo pipefail

                        # Authenticate to Vault via AppRole
                        VAULT_TOKEN=\\$(curl -sf \\
                            --request POST \\
                            --data "{\\\\\\"role_id\\\\\\": \\\\\\"${ROLE_ID}\\\\\\", \\\\\\"secret_id\\\\\\": \\\\\\"${SECRET_ID}\\\\\\"}" \\
                            "${VAULT_ADDR}/v1/auth/approle/login" \\
                            | jq -r '.auth.client_token')

                        # Fetch JFrog token from Vault
                        JFROG_TOKEN=\\$(curl -sf \\
                            --header "X-Vault-Token: \\${VAULT_TOKEN}" \\
                            "${VAULT_ADDR}/v1/secret/data/jfrog/deploy" \\
                            | jq -r '.data.data.token')

                        mkdir -p build

                        # Download platform artifact
                        curl -sf \\
                            -H "Authorization: Bearer \\${JFROG_TOKEN}" \\
                            -o "build/pgaas-${PGAAS_VERSION}.zip" \\
                            "${ARTIFACTORY_URL}/pgaas-generic-local/pgaas/${PGAAS_VERSION}/pgaas-${PGAAS_VERSION}.zip"
                        echo "Downloaded pgaas-${PGAAS_VERSION}.zip"

                        # Download users artifact
                        curl -sf \\
                            -H "Authorization: Bearer \\${JFROG_TOKEN}" \\
                            -o "build/pgaas-users-${USERS_VERSION}.zip" \\
                            "${ARTIFACTORY_URL}/pgaas-generic-local/pgaas-users/${USERS_VERSION}/pgaas-users-${USERS_VERSION}.zip"
                        echo "Downloaded pgaas-users-${USERS_VERSION}.zip"
                    """
                }
            }
        }

        stage('Assemble') {
            steps {
                sh """
                    set -euo pipefail

                    # Unzip platform artifact into workspace root
                    unzip -o "build/pgaas-${PGAAS_VERSION}.zip" -d .

                    # Unzip users artifact into confs/users/
                    mkdir -p confs/users
                    unzip -o "build/pgaas-users-${USERS_VERSION}.zip" -d confs/users/

                    echo "Assembled platform ${PGAAS_VERSION} + users ${USERS_VERSION}"
                """
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([file(
                    credentialsId: params.KUBECONFIG_CRED,
                    variable: 'KUBECONFIG'
                )]) {
                    script {
                        def insList = params.INS.split(',').collect { it.trim() }.findAll { it }
                        def dc = params.DC?.trim() ?: ''
                        def dcArg = dc ? "DC=${dc}" : ''

                        for (ins in insList) {
                            echo "Deploying INS=${ins} ENV=${env.EFFECTIVE_ENV} ACTION=${params.ACTION} ${dcArg}"
                            sh "make ${params.ACTION} INS=${ins} ENV=${env.EFFECTIVE_ENV} ${dcArg}"
                        }
                    }
                }
            }
        }
    }

    post {
        cleanup {
            cleanWs()
        }
    }
}
'''.stripIndent())
        }
    }
}
