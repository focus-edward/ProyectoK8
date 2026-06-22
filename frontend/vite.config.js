import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// El backend FastAPI corre por defecto en :8000.
// En produccion (Render) se inyecta VITE_API_URL en el build.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
})
