import bcrypt
import random

def hash_password(password):
    return bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')

def generate_sql():
    sql = []
    
    # 1. Update Ahmad Sajid
    # Since there's no ON UPDATE CASCADE, we insert new, update dependencies, delete old.
    new_reg_no = '2024338'
    old_reg_no = '24L-0941'
    ahmad_pass = hash_password('338')
    
    sql.append("-- ==========================================")
    sql.append("-- 1. UPDATE AHMAD SAJID AND ADD MOHSIN SAEED")
    sql.append("-- ==========================================")
    sql.append(f"INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('{new_reg_no}', 'Ahmad Sajid', 'ahmad_new@example.com', 2024, 'Computer Science', '{ahmad_pass}') ON CONFLICT DO NOTHING;")
    sql.append(f"UPDATE tweets SET author_reg_no = '{new_reg_no}' WHERE author_reg_no = '{old_reg_no}';")
    sql.append(f"UPDATE replies SET author_reg_no = '{new_reg_no}' WHERE author_reg_no = '{old_reg_no}';")
    sql.append(f"UPDATE likes SET user_reg_no = '{new_reg_no}' WHERE user_reg_no = '{old_reg_no}';")
    sql.append(f"UPDATE follows SET follower_reg_no = '{new_reg_no}' WHERE follower_reg_no = '{old_reg_no}';")
    sql.append(f"UPDATE follows SET following_reg_no = '{new_reg_no}' WHERE following_reg_no = '{old_reg_no}';")
    sql.append(f"UPDATE direct_messages SET sender_reg_no = '{new_reg_no}' WHERE sender_reg_no = '{old_reg_no}';")
    sql.append(f"UPDATE direct_messages SET receiver_reg_no = '{new_reg_no}' WHERE receiver_reg_no = '{old_reg_no}';")
    sql.append(f"UPDATE reports SET reporter_reg_no = '{new_reg_no}' WHERE reporter_reg_no = '{old_reg_no}';")
    sql.append(f"UPDATE reports SET reported_user_reg_no = '{new_reg_no}' WHERE reported_user_reg_no = '{old_reg_no}';")
    sql.append(f"DELETE FROM users WHERE reg_no = '{old_reg_no}';")
    
    # 2. Add Mohsin Saeed
    mohsin_reg_no = '2024307'
    mohsin_pass = hash_password('307')
    sql.append(f"INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('{mohsin_reg_no}', 'Mohsin Saeed', 'mohsin@example.com', 2024, 'Computer Science', '{mohsin_pass}') ON CONFLICT DO NOTHING;")
    
    # Main characters
    main_users = ['2024338', '2024307', '2024475', '2024903']
    
    # 3. Generate 1000 users
    sql.append("\n-- ==========================================")
    sql.append("-- 2. GENERATE 1000 USERS")
    sql.append("-- ==========================================")
    synthetic_users = []
    start_reg = 2022000
    for i in range(1000):
        reg = str(start_reg + i)
        synthetic_users.append(reg)
        pwd = reg[-3:]
        pwd_hash = hash_password(pwd)
        email = f"user_{reg}@example.com"
        name = f"Test User {i}"
        year = random.choice([2022, 2023, 2024, 2025])
        sql.append(f"INSERT INTO users (reg_no, full_name, email, batch_year, department, password_hash) VALUES ('{reg}', '{name}', '{email}', {year}, 'General', '{pwd_hash}') ON CONFLICT DO NOTHING;")

    # 4. Generate follows
    sql.append("\n-- ==========================================")
    sql.append("-- 3. GENERATE FOLLOWS")
    sql.append("-- ==========================================")
    for u in synthetic_users:
        for m in main_users:
            if u != m:
                sql.append(f"INSERT INTO follows (follower_reg_no, following_reg_no) VALUES ('{u}', '{m}') ON CONFLICT DO NOTHING;")
                
    # 5. Generate 20-30 Trending Tweets from main users
    sql.append("\n-- ==========================================")
    sql.append("-- 4. GENERATE TRENDING TWEETS (MAIN USERS)")
    sql.append("-- ==========================================")
    
    tweet_contents = [
        "Just working on the new database project! #CS",
        "Can''t believe how much data we are generating.",
        "Firebase integration was tough but we did it!",
        "Who else is up late coding?",
        "PostgreSQL rocks!",
        "Final year projects are stressful but fun.",
        "Just deployed the latest update to UniTweet.",
        "Is anyone else struggling with triggers?",
        "Beautiful UI makes a huge difference.",
        "Testing the massive synthetic dataset now!"
    ]
    
    trending_tweets = []
    num_trending = random.randint(20, 30)
    # We don't know the generated tweet_ids beforehand if we just insert, 
    # but we can insert them with DO() RETURNING or since we are generating raw SQL,
    # we can use sequence currval or just assume tweet IDs if we reset sequence.
    # A safer way to generate likes for specific tweets in SQL without knowing IDs is:
    # INSERT INTO tweets...
    # INSERT INTO likes (tweet_id, user_reg_no) SELECT tweet_id, 'user_id' FROM tweets WHERE author_reg_no = '...' ORDER BY tweet_id DESC LIMIT 1;
    # But doing this for 1000 users is slow. 
    # Let's just insert tweets, and for likes we will write a PL/pgSQL block that loops over the tweets.
    
    sql.append("DO $$")
    sql.append("DECLARE")
    sql.append("    t_id INT;")
    sql.append("    synth_users VARCHAR[] := ARRAY[" + ",".join(f"'{u}'" for u in synthetic_users[:200]) + "];") # Use first 200 for likes to keep string size manageable
    sql.append("BEGIN")
    
    for _ in range(num_trending):
        author = random.choice(main_users)
        content = random.choice(tweet_contents)
        sql.append(f"    INSERT INTO tweets (author_reg_no, content) VALUES ('{author}', '{content} - {random.randint(1,100)}') RETURNING tweet_id INTO t_id;")
        likes_count = random.randint(50, 150)
        sql.append(f"    FOR i IN 1..{likes_count} LOOP")
        sql.append(f"        INSERT INTO likes (tweet_id, user_reg_no) VALUES (t_id, synth_users[i]) ON CONFLICT DO NOTHING;")
        sql.append(f"    END LOOP;")
        
    sql.append("END $$;")

    # 6. Generate 100-1000 random tweets from synthetic users
    sql.append("\n-- ==========================================")
    sql.append("-- 5. GENERATE NORMAL TWEETS")
    sql.append("-- ==========================================")
    num_tweets = random.randint(300, 600)
    for _ in range(num_tweets):
        author = random.choice(synthetic_users)
        sql.append(f"INSERT INTO tweets (author_reg_no, content) VALUES ('{author}', 'This is a random test tweet {random.randint(1, 10000)}');")

    # 7. Generate Inbox Messages
    sql.append("\n-- ==========================================")
    sql.append("-- 6. GENERATE INBOX MESSAGES")
    sql.append("-- ==========================================")
    num_dms = random.randint(50, 100)
    for _ in range(num_dms):
        sender = random.choice(main_users)
        receiver = random.choice(synthetic_users)
        if sender != receiver:
            sql.append(f"INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('{sender}', '{receiver}', 'Hello from {sender}!');")
            sql.append(f"INSERT INTO direct_messages (sender_reg_no, receiver_reg_no, content) VALUES ('{receiver}', '{sender}', 'Hi {sender}, responding to your message.');")

    # 8. Generate Reports
    sql.append("\n-- ==========================================")
    sql.append("-- 7. GENERATE REPORTS")
    sql.append("-- ==========================================")
    for _ in range(100):
        reporter = random.choice(synthetic_users)
        reported = random.choice(synthetic_users)
        if reporter != reported:
            sql.append(f"INSERT INTO reports (reporter_reg_no, reported_user_reg_no, reason, status) VALUES ('{reporter}', '{reported}', 'Spam account', 'PENDING');")
            
    with open('mock_data.sql', 'w', encoding='utf-8') as f:
        f.write("\n".join(sql))
        
    print("mock_data.sql generated successfully! It contains " + str(len(sql)) + " lines of SQL.")

if __name__ == "__main__":
    generate_sql()
