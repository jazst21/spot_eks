from locust import HttpUser, task, between


class BookinfoUser(HttpUser):
    wait_time = between(1, 3)
    host = "http://localhost:9080"

    def on_start(self):
        self.headers = {"Cache-Control": "no-cache, no-store", "Pragma": "no-cache"}

    @task(5)
    def productpage(self):
        self.client.get("/productpage", headers=self.headers)

    @task(2)
    def api_reviews(self):
        self.client.get("/api/v1/products/0/reviews", headers=self.headers)

    @task(2)
    def api_ratings(self):
        self.client.get("/api/v1/products/0/ratings", headers=self.headers)

    @task(1)
    def health(self):
        self.client.get("/health", headers=self.headers)
