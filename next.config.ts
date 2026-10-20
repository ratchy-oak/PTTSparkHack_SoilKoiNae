import type { NextConfig } from 'next';
const nextConfig: NextConfig = {
  distDir: process.env.NAKOOM_DIST_DIR || '.next',
  serverExternalPackages: ['@electric-sql/pglite'],
  devIndicators: false,
  turbopack: { root: process.cwd() },
};
export default nextConfig;
