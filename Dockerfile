FROM nginx:1.31.5-alpine@sha256:72ba65eb42c10344912a84ff42408db7d34f2feb642204570ab8fc5ffd29f1d3
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
