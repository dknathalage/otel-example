# build (context = src/Web)
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
# NEXT_PUBLIC_* are inlined into the client bundle at build time, so they MUST be
# present here — setting them as runtime Deployment env does nothing for the browser.
# The browser now exports traces same-origin via the Next.js OTLP proxy
# (app/api/otlp/v1/traces), so this defaults to that relative path.
ARG NEXT_PUBLIC_OTLP_HTTP_URL=/api/otlp/v1/traces
ENV NEXT_PUBLIC_OTLP_HTTP_URL=$NEXT_PUBLIC_OTLP_HTTP_URL
RUN npm run build

# runtime (Next.js standalone output)
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]
