import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Same-origin requests avoid CORS configuration in the local development setup.
const proxy = { '/api': { target: process.env.API_TARGET ?? 'http://127.0.0.1:18473', changeOrigin: true, ws: true } };
export default defineConfig({
  plugins: [react()],
  server: { host: '127.0.0.1', port: 17329, strictPort: true, proxy },
  preview: { host: '127.0.0.1', port: 17329, strictPort: true, proxy },
});
