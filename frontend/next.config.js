/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  async rewrites() {
    return [
      {
        source: '/api/auth/:path*',
        destination: `${process.env.AUTH_SERVICE_URL || 'http://auth-service-svc.default.svc.cluster.local:3001'}/:path*`,
      },
      {
        source: '/api/profile/:path*',
        destination: `${process.env.PROFILE_SERVICE_URL || 'http://profile-service-svc.default.svc.cluster.local:3002'}/:path*`,
      },
    ];
  },
};

module.exports = nextConfig;
