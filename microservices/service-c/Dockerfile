FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY logging_utils.py app.py ./

# Log directory is bind-mounted from ./service-c/logs on the host.
ENV SERVICE_NAME=service-c \
    LOG_DIR=/var/log/service-c
RUN mkdir -p /var/log/service-c

EXPOSE 5003

CMD ["python", "app.py"]
