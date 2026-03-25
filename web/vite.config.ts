import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      '/m1': {
        target: 'https://localhost:8443',
        changeOrigin: true,
        secure: false,
        rewrite: (path) => path.replace(/^\/m1/, ''),
      },
      '/m2': {
        target: 'https://localhost:9443',
        changeOrigin: true,
        secure: false,
        rewrite: (path) => path.replace(/^\/m2/, ''),
      },
    }
  },
  build: {
    outDir: 'dist',
  }
})
