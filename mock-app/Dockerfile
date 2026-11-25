FROM python:3.12-alpine

RUN adduser -D -u 10001 appuser && apk add --no-cache curl bind-tools

WORKDIR /app
COPY app.py /app/app.py

USER appuser
EXPOSE 8080

CMD ["python3", "/app/app.py"]
