# Forest Coffee CTRM

Sistema de gestión de hedge y coberturas KC — **Forest Coffee**.

Aplicación web progresiva (PWA) estática desplegada en Netlify, con una función
serverless que actúa como proxy hacia la API de Claude.

## Estructura

```
.
├── index.html                      # Aplicación principal (PWA)
├── manifest.json                   # Manifiesto PWA
├── sw.js                           # Service Worker
├── favicon.ico
├── icons/                          # Iconos de la aplicación
├── netlify.toml                    # Configuración de build/headers/redirects
├── _redirects                      # Reglas de redirección (fallback)
└── netlify/
    └── functions/
        └── claude-proxy.js         # Proxy serverless hacia la API de Claude
```

## Despliegue (Netlify)

El sitio se publica desde la raíz del repositorio (`publish = "."`).
Las funciones serverless se ubican en `netlify/functions/`.

La función `claude-proxy` reenvía las solicitudes a `https://api.anthropic.com/v1/messages`.
La API key se envía por petición mediante el header `x-api-key` (no se almacena en el repositorio).

## Desarrollo local

```bash
# Servir el sitio estático
npx serve .

# O con la CLI de Netlify (incluye las funciones)
netlify dev
```
