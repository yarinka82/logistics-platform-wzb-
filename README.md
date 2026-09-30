# Logistics Platform WZB

A React + TypeScript & FastAPI + PostgreSQL freight marketplace starter template designed for junior developers to practice Clean Architecture and TDD.

## Prerequisites
- Docker & Docker Compose v2
- Node.js 22.12+

## Setup & Run

1. **Environment Setup:**
   Copy the example environment file:
   ```bash
   cp .env.example .env
   ```
   *(Ensure `JWT_SECRET` is set in `.env`)*

2. **Start the Backend & Database:**
   ```bash
   docker compose up --build -d
   ```

3. **Start the Frontend:**
   ```bash
   cd frontend
   npm ci
   npm run dev
   ```

## Useful Links
- **Frontend App**: [http://localhost:17329](http://localhost:17329)
- **Backend API Docs (Swagger)**: [http://localhost:18473/docs](http://localhost:18473/docs)
- **PostgreSQL Port**: `16439`

## Default Credentials
- **Admin Login**: `admin` / `123456`
- **SMS Mock Activation Code**: `0000`
