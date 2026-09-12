# Upstream Pokemon Showdown, unpatched, at the commit pokebot pins
# (src/pokebot/server/manager.py SHOWDOWN_PIN) so the mechanics the pilots train
# against are the ones a human meets. `--no-security` is the preset for
# nothrottle + noguestsecurity + noipchecks (server/config-loader.ts at the pin):
# passwordless names, exactly as `pokebot serve` runs locally. The port is
# positional because without a numeric argv token Showdown's cloud-autoconfigure
# branch overrides the bind address (manager.start's docstring); --skip-build
# because dist/ is built here, once, and the launcher would otherwise rebuild on
# every container start.
FROM node:22-alpine
ARG SHOWDOWN_PIN=6a1836dd71c0718e923206f3d089e61074410868

RUN apk add --no-cache git
WORKDIR /showdown
RUN git init -q . \
 && git remote add origin https://github.com/smogon/pokemon-showdown.git \
 && git fetch -q --depth 1 origin "$SHOWDOWN_PIN" \
 && git checkout -q FETCH_HEAD \
 && npm install --no-audit --no-fund \
 && node build \
 && cp config/config-example.js config/config.js \
 && chown -R node:node /showdown

USER node
EXPOSE 8000
CMD ["node", "pokemon-showdown", "start", "8000", "--no-security", "--skip-build"]
