pipeline {
    agent any

    environment {
        VAULT_ADDR      = "${env.VAULT_ADDR}"
        ARTIFACTORY_URL = "${env.ARTIFACTORY_URL}"
    }

    stages {
        stage('Derive Version') {
            steps {
                script {
                    if (env.TAG_NAME?.startsWith('v')) {
                        env.VERSION = env.TAG_NAME.replaceFirst(/^v/, '')
                        env.IS_RELEASE = 'true'
                    } else {
                        def shortSha = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                        def branch = env.BRANCH_NAME ?: sh(script: 'git rev-parse --abbrev-ref HEAD', returnStdout: true).trim()
                        env.VERSION = "0.0.0-${branch}.${shortSha}"
                        env.IS_RELEASE = 'false'
                    }
                    echo "Version: ${env.VERSION} (release: ${env.IS_RELEASE})"
                }
            }
        }

        stage('Check Tools') {
            steps {
                sh 'make check-tools'
            }
        }

        stage('Preview') {
            steps {
                sh 'make preview'
            }
        }

        stage('Package') {
            when {
                expression { env.IS_RELEASE == 'true' }
            }
            steps {
                sh '''
                    mkdir -p build
                    zip -r "build/pgaas-${VERSION}.zip" \
                        scripts/ core/ confs/admin/ manifests/ helmfile.yaml Makefile \
                        -x '*.git*' \
                        -x 'confs/_generated/*' \
                        -x 'confs/admin/local/*'
                '''
                archiveArtifacts artifacts: "build/pgaas-${VERSION}.zip", fingerprint: true
            }
        }

        stage('Publish') {
            when {
                expression { env.IS_RELEASE == 'true' }
            }
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'APPROLE_CRED',
                    usernameVariable: 'ROLE_ID',
                    passwordVariable: 'SECRET_ID'
                )]) {
                    sh '''
                        set -euo pipefail

                        # Authenticate to Vault via AppRole
                        VAULT_TOKEN=$(curl -sf \
                            --request POST \
                            --data "{\\\"role_id\\\": \\\"${ROLE_ID}\\\", \\\"secret_id\\\": \\\"${SECRET_ID}\\\"}" \
                            "${VAULT_ADDR}/v1/auth/approle/login" \
                            | jq -r '.auth.client_token')

                        # Fetch JFrog token from Vault
                        JFROG_TOKEN=$(curl -sf \
                            --header "X-Vault-Token: ${VAULT_TOKEN}" \
                            "${VAULT_ADDR}/v1/secret/data/jfrog/deploy" \
                            | jq -r '.data.data.token')

                        # Upload artifact to Artifactory
                        curl -sf \
                            -H "Authorization: Bearer ${JFROG_TOKEN}" \
                            -T "build/pgaas-${VERSION}.zip" \
                            "${ARTIFACTORY_URL}/pgaas-generic-local/pgaas/${VERSION}/pgaas-${VERSION}.zip"

                        echo "Published pgaas-${VERSION}.zip to Artifactory"
                    '''
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
