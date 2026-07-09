# -*- coding: utf-8 -*-
import os, sys, io

if sys.platform == "win32":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8")

from flask import Flask, jsonify, request, render_template
from flask_cors import CORS
from dotenv import load_dotenv
from openai import OpenAI

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))
from db import get_connection

DEEPSEEK_API_KEY = os.getenv("DEEPSEEK_API_KEY")
DEEPSEEK_BASE_URL = os.getenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
DEEPSEEK_MODEL = os.getenv("DEEPSEEK_MODEL", "deepseek-chat")

app = Flask(__name__)
CORS(app)


# REST API

def _range_filter(r):
    """Generate SQL date filter by range param"""
    if r == "today":
        return "DATE(o.created_at) = CURDATE()"
    elif r == "7d":
        return "o.created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)"
    elif r == "30d":
        return "o.created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)"
    elif r == "month":
        return "DATE_FORMAT(o.created_at, '%Y-%m') = DATE_FORMAT(NOW(), '%Y-%m')"
    else:
        return "1=1"


@app.route("/api/today_stats")
def today_stats():
    conn = get_connection()
    try:
        stats = {}
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM orders WHERE DATE(created_at) = CURDATE()")
            stats["today_orders"] = cur.fetchone()[0]
            cur.execute("""
                SELECT IFNULL(SUM(total_amount), 0) FROM orders
                WHERE DATE(created_at) = CURDATE() AND order_status = 'Completed'
            """)
            stats["today_revenue"] = float(cur.fetchone()[0])
            cur.execute("SELECT COUNT(*) FROM riders WHERE status = 'Delivering'")
            stats["active_riders"] = cur.fetchone()[0]
            cur.execute("SELECT COUNT(DISTINCT merchant_id) FROM orders WHERE DATE(created_at) = CURDATE()")
            stats["active_merchants"] = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM vw_pickup_point_analytics WHERE saturation_pct > 80")
            stats["overflow_points"] = cur.fetchone()[0]
        return jsonify(stats)
    finally:
        conn.close()


@app.route("/api/order_status")
def order_status():
    r = request.args.get("range", "today")
    filt = _range_filter(r)
    conn = get_connection()
    try:
        sql = f"""
            SELECT order_status, COUNT(*) AS cnt FROM orders o
            WHERE {filt} GROUP BY order_status ORDER BY cnt DESC
        """
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        return jsonify([{"status": row[0], "count": row[1]} for row in rows])
    finally:
        conn.close()


@app.route("/api/pickup_points")
def pickup_points():
    conn = get_connection()
    try:
        sql = """
            SELECT point_name, max_capacity, current_packages, saturation_pct, backlog_count
            FROM vw_pickup_point_analytics
        """
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        return jsonify([{
            "name": row[0].replace("Smart Locker", "").strip(),
            "capacity": row[1], "packages": row[2],
            "saturation": round(float(row[3]), 1), "backlog": row[4],
        } for row in rows])
    finally:
        conn.close()


@app.route("/api/merchant_rank")
def merchant_rank():
    r = request.args.get("range", "today")
    filt = _range_filter(r)
    conn = get_connection()
    try:
        sql = f"""
            SELECT m.merchant_name, COUNT(DISTINCT o.order_id) AS orders,
                   IFNULL(SUM(o.total_amount), 0) AS sales
            FROM merchants m
            LEFT JOIN orders o ON m.merchant_id = o.merchant_id
                AND o.order_status = 'Completed' AND {filt}
            GROUP BY m.merchant_id
            ORDER BY sales DESC LIMIT 10
        """
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        return jsonify([{"name": row[0], "orders": row[1], "sales": float(row[2])} for row in rows])
    finally:
        conn.close()


@app.route("/api/recent_orders")
def recent_orders():
    limit = request.args.get("limit", 20, type=int)
    conn = get_connection()
    try:
        sql = f"""
            SELECT o.order_id, u.username, m.merchant_name, o.total_amount,
                   o.order_status, DATE_FORMAT(o.created_at, '%Y-%m-%d %H:%i') AS t
            FROM orders o
            JOIN users u ON o.user_id = u.user_id
            JOIN merchants m ON o.merchant_id = m.merchant_id
            ORDER BY o.created_at DESC LIMIT {limit}
        """
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        return jsonify([{
            "id": row[0], "user": row[1], "merchant": row[2],
            "amount": float(row[3]), "status": row[4], "time": row[5],
        } for row in rows])
    finally:
        conn.close()


@app.route("/api/hourly_dist")
def hourly_dist():
    r = request.args.get("range", "today")
    filt = _range_filter(r)
    conn = get_connection()
    try:
        sql = f"""
            SELECT HOUR(o.created_at) AS h, COUNT(*) AS cnt,
                   ROUND(AVG(o.total_amount), 2) AS avg_amount
            FROM orders o WHERE {filt}
            GROUP BY HOUR(o.created_at) ORDER BY h
        """
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        return jsonify([{"hour": row[0], "count": row[1], "avg_amount": float(row[2])} for row in rows])
    finally:
        conn.close()


@app.route("/api/side_tables")
def side_tables():
    conn = get_connection()
    try:
        result = {}
        with conn.cursor() as cur:
            cur.execute("SELECT merchant_id, merchant_name, phone, rating FROM merchants ORDER BY merchant_id")
            result["merchants"] = [{"id": r[0], "name": r[1], "phone": r[2], "rating": float(r[3])} for r in cur.fetchall()]
            cur.execute("SELECT user_id, username, phone, dorm_building, balance FROM users ORDER BY user_id")
            result["users"] = [{"id": r[0], "name": r[1], "phone": r[2], "dorm": r[3], "balance": float(r[4])} for r in cur.fetchall()]
            cur.execute("""
                SELECT d.dish_name, d.price, d.stock, m.merchant_name
                FROM dishes d JOIN merchants m ON d.merchant_id = m.merchant_id
                ORDER BY m.merchant_name
            """)
            result["dishes"] = [{"name": r[0], "price": float(r[1]), "stock": r[2], "merchant": r[3]} for r in cur.fetchall()]
            cur.execute("SELECT rider_name, phone, rider_type, status FROM riders ORDER BY rider_id")
            result["riders"] = [{"name": r[0], "phone": r[1], "type": r[2], "status": r[3]} for r in cur.fetchall()]
            cur.execute("SELECT point_name, location, capacity, current_packages FROM pickup_points ORDER BY point_id")
            result["points"] = [{"name": r[0], "location": r[1], "capacity": r[2], "packages": r[3]} for r in cur.fetchall()]
        return jsonify(result)
    finally:
        conn.close()


# AI Text-to-SQL

DB_SCHEMA = """Database: campus_delivery_db (Campus Two-Stage Delivery)
Tables:
  users(user_id,username,phone,dorm_building,room_number,balance DECIMAL)
  merchants(merchant_id,merchant_name,phone,address,rating DECIMAL(2,1) max 5.0)
  dishes(dish_id,merchant_id INT FK,dish_name,price DECIMAL,stock INT,status INT: 1=on_sale 0=off_sale)
  pickup_points(point_id,point_name,location,capacity INT,current_packages INT)
  riders(rider_id,rider_name,phone,rider_type ENUM: 'Stage1_Trunk'=trunk-to-point 'Stage2_Floor'=point-to-dorm, status ENUM: 'Idle' 'Delivering' 'Offline')
  orders(order_id,user_id FK,merchant_id FK,pickup_point_id FK,total_amount DECIMAL,order_status ENUM: 'Paid' 'Stage1_Assigned' 'Arrived_At_Point' 'Stage2_Assigned' 'Completed' 'Cancelled', stage1_rider_id FK,stage2_rider_id FK,created_at DATETIME,stage1_completed_at DATETIME,stage2_completed_at DATETIME)
  order_items(item_id,order_id FK,dish_id FK,quantity INT,price_at_order DECIMAL)
Views: vw_pickup_point_analytics, vw_merchant_sales_rank
Important: status=1 for available dishes. order_status='Completed' for completed orders. FK means foreign key. All amounts in CNY. Use Chinese column aliases. Return raw SQL without markdown."""


@app.route("/api/ai_query", methods=["POST"])
def ai_query():
    data = request.get_json()
    question = data.get("question", "").strip()
    if not question:
        return jsonify({"success": False, "error": "Question cannot be empty"})

    if not DEEPSEEK_API_KEY:
        return jsonify({"success": False, "error": "DeepSeek API Key not configured"})

    client = OpenAI(api_key=DEEPSEEK_API_KEY, base_url=DEEPSEEK_BASE_URL, timeout=10)
    try:
        response = client.chat.completions.create(
            model=DEEPSEEK_MODEL,
            messages=[
                {"role": "system", "content": f"You are a Text-to-SQL assistant. Schema:\n{DB_SCHEMA}"},
                {"role": "user", "content": question}
            ],
            temperature=0.1, max_tokens=1000, timeout=10,
        )
        sql = response.choices[0].message.content.strip()
        sql = sql.replace("```sql", "").replace("```", "").strip()

        if not sql.upper().startswith("SELECT"):
            return jsonify({"success": False, "sql": sql, "error": "Non-SELECT statement blocked"})

        dangerous = ["INSERT ","UPDATE ","DELETE ","DROP ","ALTER ","TRUNCATE ","CREATE ","EXEC "]
        for kw in dangerous:
            if kw in sql.upper():
                return jsonify({"success": False, "sql": sql, "error": f"Dangerous keyword: {kw.strip()}"})

        conn = get_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(sql)
                rows = cur.fetchall()
                cols = [d[0] for d in cur.description]
            return jsonify({"success": True, "sql": sql, "columns": cols, "rows": [list(r) for r in rows]})
        finally:
            conn.close()
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})


# Main page

@app.route("/")
def index():
    return render_template("index.html")


if __name__ == "__main__":
    print("\n  校园外卖两段式配送系统")
    print("  http://localhost:5000\n")
    app.run(host="0.0.0.0", port=5000, debug=False)
