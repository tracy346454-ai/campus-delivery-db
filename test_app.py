import sys, io, unittest, os

if sys.platform == "win32":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8")

from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

from app import app
from db import check_connection


class TestDatabaseConnection(unittest.TestCase):
    """数据库连接测试"""

    def test_db_reachable(self):
        ok, msg = check_connection()
        self.assertTrue(ok, f"数据库不可达: {msg}")


class TestAPIEndpoints(unittest.TestCase):
    """API 接口测试"""

    @classmethod
    def setUpClass(cls):
        cls.client = app.test_client()

    def test_index_returns_html(self):
        resp = self.client.get("/")
        self.assertEqual(resp.status_code, 200)
        self.assertIn(b"<!DOCTYPE html>", resp.data)

    def test_today_stats(self):
        resp = self.client.get("/api/today_stats")
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertIn("today_orders", data)
        self.assertIn("today_revenue", data)
        self.assertIn("active_riders", data)
        self.assertIn("active_merchants", data)
        self.assertIn("overflow_points", data)

    def test_order_status_all_ranges(self):
        for r in ["today", "7d", "30d", "month", "all"]:
            with self.subTest(range=r):
                resp = self.client.get(f"/api/order_status?range={r}")
                self.assertEqual(resp.status_code, 200)
                self.assertIsInstance(resp.get_json(), list)

    def test_pickup_points(self):
        resp = self.client.get("/api/pickup_points")
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertIsInstance(data, list)
        if data:
            self.assertIn("name", data[0])
            self.assertIn("saturation", data[0])

    def test_merchant_rank(self):
        resp = self.client.get("/api/merchant_rank?range=today")
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertIsInstance(data, list)
        self.assertLessEqual(len(data), 10)

    def test_recent_orders(self):
        resp = self.client.get("/api/recent_orders?limit=5")
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertIsInstance(data, list)
        self.assertLessEqual(len(data), 5)

    def test_hourly_dist(self):
        resp = self.client.get("/api/hourly_dist?range=today")
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertIsInstance(data, list)

    def test_side_tables(self):
        resp = self.client.get("/api/side_tables")
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertIn("merchants", data)
        self.assertIn("users", data)
        self.assertIn("dishes", data)
        self.assertIn("riders", data)
        self.assertIn("points", data)

    def test_ai_query_empty_rejected(self):
        resp = self.client.post("/api/ai_query",
                                json={"question": ""})
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertFalse(data["success"])

    def test_ai_query_no_api_key(self):
        if not os.getenv("DEEPSEEK_API_KEY"):
            resp = self.client.post("/api/ai_query",
                                    json={"question": "测试"})
            data = resp.get_json()
            self.assertIn("error", data)
        else:
            self.skipTest("DeepSeek API Key 已配置，跳过无 Key 测试")


if __name__ == "__main__":
    unittest.main(verbosity=2)
