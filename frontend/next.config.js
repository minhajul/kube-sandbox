/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  async rewrites() {
    return [
      {
        source: '/api/auth/:path*',
        destination: `${process.env.AUTH_SERVICE_URL || 'http://apps-kube-sandbox-auth:3001'}/:path*`,
      },
      {
        source: '/api/profile/:path*',
        destination: `${process.env.PROFILE_SERVICE_URL || 'http://apps-kube-sandbox-profile:3002'}/:path*`,
      },
    ];
  },
};

module.exports = nextConfig;
