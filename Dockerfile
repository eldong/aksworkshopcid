# Use a small, production-ready Nginx image to serve the static files.
FROM nginx:1.27-alpine

# Replace the default Nginx site with this project's website.
COPY website/ /usr/share/nginx/html/

# Document the HTTP port used by Nginx and the Kubernetes Service.
EXPOSE 80
