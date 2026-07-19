# ============================================================================
# Kube Sandbox — Tilt Configuration for Instant Local Live-Reloading
# ============================================================================

# 1. Build the Docker images locally.
# Tilt automatically matches these builds to the image repositories in K8s.
docker_build(
    'auth-service',
    context='backend/auth-service',
    dockerfile='backend/auth-service/Dockerfile',
    only=['src', 'package.json', 'tsconfig.json', 'nest-cli.json']
)

docker_build(
    'profile-service',
    context='backend/profile-service',
    dockerfile='backend/profile-service/Dockerfile',
    only=['src', 'package.json', 'tsconfig.json', 'nest-cli.json']
)

docker_build(
    'frontend',
    context='frontend',
    dockerfile='frontend/Dockerfile',
    only=['src', 'package.json', 'tsconfig.json', 'next.config.js']
)

# 2. Render and Deploy the Helm Chart.
# We override the image settings so Kubernetes pulls the locally built images.
app_yaml = helm(
    'infrastructure/charts/kube-sandbox',
    name='apps',
    namespace='default',
    values=['infrastructure/charts/kube-sandbox/values.yaml'],
    set=[
        'org=library',
        'apps.auth.image.repository=auth-service',
        'apps.auth.image.tag=local',
        'apps.auth.image.pullPolicy=Never',
        'apps.profile.image.repository=profile-service',
        'apps.profile.image.tag=local',
        'apps.profile.image.pullPolicy=Never',
        'apps.frontend.image.repository=frontend',
        'apps.frontend.image.tag=local',
        'apps.frontend.image.pullPolicy=Never',
    ]
)
k8s_yaml(app_yaml)

# 3. Configure port-forwarding directly inside Tilt.
# Tilt will automatically expose these ports on your host machine.
k8s_resource('frontend', port_forwards=['8081:3000'])
k8s_resource('apps-kube-sandbox-auth', port_forwards=['3001'])
k8s_resource('apps-kube-sandbox-profile', port_forwards=['3002'])
