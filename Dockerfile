# syntax=docker/dockerfile:1

# ---- deps: install all dependencies (dev deps are needed for the build) ----
FROM node:22-alpine AS deps
WORKDIR /app
RUN apk add --no-cache libc6-compat
COPY package.json package-lock.json ./
# --ignore-scripts skips the native build of better-sqlite3 (only used by tests).
RUN npm ci --ignore-scripts

# ---- build: compile the Next.js app ----
FROM node:22-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
# NEXT_PUBLIC_* values are inlined at build time. Railway passes service
# variables as build args when they are declared here.
ARG NEXT_PUBLIC_APP_URL
ARG NEXT_PUBLIC_BASE_URL
ENV NEXT_PUBLIC_APP_URL=$NEXT_PUBLIC_APP_URL \
    NEXT_PUBLIC_BASE_URL=$NEXT_PUBLIC_BASE_URL
# Webpack instead of Turbopack: Turbopack's file tracer fails on the
# `new Worker(...)` in src/lib/postgres-sync.js. The DB client is created at
# import time, so a placeholder URL is needed; no connection is made during
# the build. The real DATABASE_URL is supplied at runtime.
RUN DATABASE_URL=postgresql://build:build@127.0.0.1:1/build npm run build \
 && npm prune --omit=dev

# ---- runtime ----
FROM node:22-alpine AS runner
WORKDIR /app
# psql is used by the entrypoint to initialize an empty database.
RUN apk add --no-cache libc6-compat postgresql-client

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# The app resolves these from process.cwd() at runtime:
#   scripts/postgres-sync-worker.cjs (DB worker thread, requires node_modules/pg)
#   src/data/*.json                  (initiatives data)
COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/.next ./.next
COPY --from=build --chown=node:node /app/public ./public
COPY --from=build --chown=node:node /app/next.config.mjs ./next.config.mjs
COPY --from=build --chown=node:node /app/scripts ./scripts
COPY --from=build --chown=node:node /app/src/data ./src/data
COPY --from=build --chown=node:node /app/database ./database
COPY --from=build --chown=node:node /app/asrs_db.sql ./asrs_db.sql
COPY --chown=node:node docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER node
EXPOSE 3000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["sh", "-c", "exec node_modules/.bin/next start -H 0.0.0.0 -p ${PORT}"]
