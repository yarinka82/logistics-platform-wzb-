# Stage 1: Build the React/Vite app
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: Serve with Nginx
FROM nginx:alpine
# Remove default Nginx config
RUN rm /etc/nginx/conf.d/default.conf
# Copy our custom Nginx config
COPY nginx.conf /etc/nginx/conf.d/
# Copy the built frontend app
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
