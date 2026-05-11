import db
import firebase
import psycopg2

def backup_postgres_to_firebase():
    """Reads all rows from Postgres and writes them to Firebase."""
    tables = ['users', 'tweets', 'likes', 'replies', 'follows', 'direct_messages', 'reports']
    total_synced = 0
    fb_db = firebase.get_db()
    
    if not fb_db:
        print("Could not connect to Firebase.")
        return 0

    for table in tables:
        rows = db.execute_query(f"SELECT * FROM {table}")
        if not rows:
            print(f"Syncing {table}... 0 records")
            continue
            
        print(f"Syncing {table}... {len(rows)} records")
        for row in rows:
            try:
                # Determine the appropriate document ID based on the table
                if table == 'users':
                    fb_db.collection(table).document(str(row['reg_no'])).set(row)
                elif table == 'tweets':
                    fb_db.collection(table).document(str(row['tweet_id'])).set(row)
                elif table == 'likes':
                    fb_db.collection(table).document(str(row['like_id'])).set(row)
                elif table == 'replies':
                    fb_db.collection(table).document(str(row['reply_id'])).set(row)
                elif table == 'follows':
                    fb_db.collection(table).document(f"{row['follower_reg_no']}_{row['following_reg_no']}").set(row)
                elif table == 'direct_messages':
                    fb_db.collection(table).document(str(row['message_id'])).set(row)
                elif table == 'reports':
                    fb_db.collection(table).document(str(row['report_id'])).set(row)
                total_synced += 1
            except Exception as e:
                print(f"Error syncing {table} row to Firebase: {e}")
                
    print(f"Backup Complete — {total_synced} records transferred")
    return total_synced

def sync_table(table_name):
    """Syncs one specific table from Postgres to Firebase."""
    tables = ['users', 'tweets', 'likes', 'replies', 'follows', 'direct_messages', 'reports']
    if table_name not in tables:
        print(f"Invalid table name. Choose from: {', '.join(tables)}")
        return 0
        
    fb_db = firebase.get_db()
    if not fb_db:
        print("Could not connect to Firebase.")
        return 0

    rows = db.execute_query(f"SELECT * FROM {table_name}")
    if not rows:
        print(f"Syncing {table_name}... 0 records")
        return 0
        
    print(f"Syncing {table_name}... {len(rows)} records")
    total_synced = 0
    for row in rows:
        try:
            if table_name == 'users':
                fb_db.collection(table_name).document(str(row['reg_no'])).set(row)
            elif table_name == 'tweets':
                fb_db.collection(table_name).document(str(row['tweet_id'])).set(row)
            elif table_name == 'likes':
                fb_db.collection(table_name).document(str(row['like_id'])).set(row)
            elif table_name == 'replies':
                fb_db.collection(table_name).document(str(row['reply_id'])).set(row)
            elif table_name == 'follows':
                fb_db.collection(table_name).document(f"{row['follower_reg_no']}_{row['following_reg_no']}").set(row)
            elif table_name == 'direct_messages':
                fb_db.collection(table_name).document(str(row['message_id'])).set(row)
            elif table_name == 'reports':
                fb_db.collection(table_name).document(str(row['report_id'])).set(row)
            total_synced += 1
        except Exception as e:
            print(f"Error syncing {table_name} row to Firebase: {e}")
            
    print(f"Table Sync Complete — {total_synced} records transferred")
    return total_synced

def restore_firebase_to_postgres():
    """Reads all rows from Firebase and restores to Postgres."""
    # Ordered to respect foreign key constraints: users must exist before tweets, etc.
    tables = ['users', 'tweets', 'replies', 'likes', 'follows', 'direct_messages', 'reports']
    
    fb_db = firebase.get_db()
    if not fb_db:
        print("Could not connect to Firebase.")
        return 0
        
    total_restored = 0
    conn = db.get_connection()
    # Turn on autocommit so that if one row violates a unique constraint, 
    # it doesn't abort the entire transaction block for the rest of the rows
    conn.autocommit = True 
    cur = conn.cursor()
    
    for table in tables:
        docs = fb_db.collection(table).stream()
        docs_list = [doc.to_dict() for doc in docs]
        
        print(f"Restoring {table}... {len(docs_list)} records found in Firebase")
        
        restored_for_table = 0
        for doc in docs_list:
            try:
                columns = list(doc.keys())
                values = list(doc.values())
                
                # Format columns and placeholders
                col_str = ", ".join(columns)
                val_placeholders = ", ".join(["%s"] * len(values))
                
                # Determine primary key for ON CONFLICT DO NOTHING
                conflict_col = ""
                if table == 'users': conflict_col = "reg_no"
                elif table == 'tweets': conflict_col = "tweet_id"
                elif table == 'likes': conflict_col = "like_id"
                elif table == 'replies': conflict_col = "reply_id"
                elif table == 'follows': conflict_col = "follower_reg_no, following_reg_no"
                elif table == 'direct_messages': conflict_col = "message_id"
                elif table == 'reports': conflict_col = "report_id"
                
                sql = f"INSERT INTO {table} ({col_str}) VALUES ({val_placeholders}) ON CONFLICT ({conflict_col}) DO NOTHING"
                
                cur.execute(sql, values)
                if cur.rowcount > 0:
                    restored_for_table += 1
                    total_restored += 1
            except psycopg2.Error as db_err:
                # Catching duplicate keys or other db errors that couldn't be caught by ON CONFLICT
                pass
            except Exception as e:
                print(f"Error inserting document into {table}: {e}")
        
        print(f"  -> Restored {restored_for_table} new records to {table}")
        
    cur.close()
    conn.close()
    print(f"Restore Complete — {total_restored} records restored")
    return total_restored

if __name__ == "__main__":
    while True:
        print("\n--- UniTweet Data Transfer Script ---")
        print("1. Backup Postgres → Firebase")
        print("2. Restore Firebase → Postgres")  
        print("3. Sync single table")
        print("4. Exit")
        choice = input("Choose (1-4): ")
        
        if choice == '1':
            backup_postgres_to_firebase()
        elif choice == '2':
            restore_firebase_to_postgres()
        elif choice == '3':
            table = input("Enter table name (e.g. users, tweets, follows): ")
            sync_table(table)
        elif choice == '4':
            print("Exiting...")
            break
        else:
            print("Invalid choice. Please choose 1-4.")
