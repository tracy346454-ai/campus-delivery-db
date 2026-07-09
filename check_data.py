import sys, io, os

if sys.platform == "win32":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8")

import pymysql
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

def main():
    conn = None
    ok = True
    try:
        conn = pymysql.connect(
            host=os.getenv('MYSQL_HOST', 'localhost'),
            user=os.getenv('MYSQL_USER', 'root'),
            password=os.getenv('MYSQL_PASSWORD'),
            database=os.getenv('MYSQL_DATABASE', 'campus_delivery_db'),
            charset=os.getenv('MYSQL_CHARSET', 'utf8mb4'),
        )
        with conn.cursor() as cur:
            # Row counts
            cur.execute('SELECT COUNT(*) FROM users'); u = cur.fetchone()[0]
            cur.execute('SELECT COUNT(*) FROM merchants'); m = cur.fetchone()[0]
            cur.execute('SELECT COUNT(*) FROM dishes'); d = cur.fetchone()[0]
            cur.execute('SELECT COUNT(*) FROM orders'); o = cur.fetchone()[0]
            cur.execute('SELECT COUNT(*) FROM riders'); r = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM riders WHERE status='Delivering'"); rd = cur.fetchone()[0]
            cur.execute('SELECT COUNT(*) FROM pickup_points'); p = cur.fetchone()[0]

            # Capacity overflow check
            cur.execute('SELECT point_name, current_packages, capacity FROM pickup_points WHERE current_packages > capacity')
            overflow = cur.fetchall()

            # Completed orders without stage2_completed_at
            cur.execute("SELECT COUNT(*) FROM orders WHERE order_status='Completed' AND stage2_completed_at IS NULL")
            bad_completed = cur.fetchone()[0]

            # Orphan order_items
            cur.execute("SELECT COUNT(*) FROM order_items WHERE order_id NOT IN (SELECT order_id FROM orders)")
            orphans = cur.fetchone()[0]

            # Negative balance
            cur.execute("SELECT COUNT(*) FROM users WHERE balance < 0")
            neg_balance = cur.fetchone()[0]

            # Dishes with negative stock
            cur.execute("SELECT COUNT(*) FROM dishes WHERE stock < 0")
            neg_stock = cur.fetchone()[0]

            # All points for display
            cur.execute('SELECT point_name, current_packages, capacity FROM pickup_points')
            points = cur.fetchall()

        # Output
        print(f'{u}学生 {m}商家 {d}菜品 {o}订单 {r}骑手({rd}在途) {p}寄存点')
        for pt in points:
            pct = pt[1] / pt[2] * 100
            print(f'  {pt[0]}: {pt[1]}/{pt[2]} ({pct:.1f}%)')

        if overflow:
            ok = False
            print(f'\n异常: {len(overflow)} 个寄存点超容量上限')
            for pt in overflow:
                print(f'  {pt[0]}: {pt[1]}/{pt[2]}')

        if bad_completed:
            ok = False
            print(f'\n异常: {bad_completed} 条 Completed 订单缺少签收时间戳')

        if orphans:
            ok = False
            print(f'\n异常: {orphans} 条订单明细指向不存在的订单')

        if neg_balance:
            ok = False
            print(f'\n异常: {neg_balance} 个学生余额为负数')

        if neg_stock:
            ok = False
            print(f'\n异常: {neg_stock} 道菜品库存为负数')

        if ok:
            print('\n完整性检查通过')

    except Exception as e:
        print(f"检查失败: {e}")
        raise
    finally:
        if conn:
            conn.close()

if __name__ == "__main__":
    main()
