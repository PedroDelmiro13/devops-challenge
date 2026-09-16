FROM node:20-alpine

WORKDIR /api

COPY package*.json ./

RUN npm ci --only=production

COPY . .

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

ENV NODE_ENV=production

EXPOSE 3000

CMD ["node", "api/index.js"]