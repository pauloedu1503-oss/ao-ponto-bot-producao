FROM node:22-bookworm-slim

WORKDIR /app/whatsapp_bridge

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY index.js ./

VOLUME ["/app/whatsapp_bridge/auth_info", "/app/whatsapp_bridge/storage"]

CMD ["node", "index.js"]
