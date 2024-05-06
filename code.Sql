/* ETL Process */
WITH sequence_per_session AS (
    SELECT DISTINCT 
        session_id,
        MIN(sequence_number) AS first_sequence_number,
        MAX(sequence_number) AS last_sequence_number
    FROM 
        events
    GROUP BY 
        session_id
), first_event_per_session AS (
    SELECT
        sps.session_id,
        e.event_type AS first_action
    FROM
        events AS e
    JOIN
        sequence_per_session AS sps
    ON 
        sps.session_id = e.session_id AND sps.first_sequence_number = e.sequence_number
), last_event_per_session AS (
    SELECT
        sps.session_id,
        e.event_type AS last_action
    FROM
        events AS e
    JOIN
       sequence_per_session AS sps
    ON 
        sps.session_id = e.session_id AND sps.last_sequence_number = e.sequence_number
), 
main AS (
    SELECT 
        session_id,
        user_id,
        event_type,
        created_at,
        COALESCE(created_at - LAG(created_at, 1) OVER (PARTITION BY session_id ORDER BY created_at), INTERVAL '0') AS difference_between_actions,
        CASE 
            WHEN event_type = 'product' THEN LEAD(created_at) OVER (PARTITION BY session_id ORDER BY created_at) - created_at
            ELSE NULL
        END AS time_spent_on_product
    FROM 
        events
),
product_viewed_in_the_session AS (
    SELECT
        session_id,
        uri,
        REGEXP_REPLACE(uri, '/product/(\d+)', E'\\1') AS product
    FROM 
        events
    WHERE 
        event_type = 'product'
), 
session_summary AS (
    SELECT 
        e.session_id,
        e.traffic_source,
        e.user_id,
        pv.product,
        MIN(e.created_at) AS session_begins,
        MAX(e.created_at) AS session_ends,
        MAX(e.created_at) - MIN(e.created_at) AS duration,
        MAX(e.sequence_number) AS number_of_actions,
        AVG(difference_between_actions) AS Average_time_between_actions,
		AVG(time_spent_on_product),
        fe.first_action,
        le.last_action
    FROM 
        events AS e
    JOIN 
        last_event_per_session AS le 
        ON e.session_id = le.session_id
    JOIN
        first_event_per_session as fe 
        ON e.session_id = fe.session_id
    JOIN 
        product_viewed_in_the_session AS pv 
        ON e.session_id = pv.session_id
    JOIN main as m
        ON m.session_id=e.session_id
    GROUP BY 
        e.session_id,
        e.user_id,
        e.traffic_source,

        pv.product,
		fe.first_action,
        le.last_action
    ORDER BY 
        session_begins ASC
)
CREATE TABLE session_summaries AS
SELECT * FROM session_summary
	
---> RFM Analysis:
	
WITH 
Activation_hub AS (
    SELECT 
        u.user_id,
        u.created_at AS "Signing up Date",
        MIN(s.session_begins) AS "The First Login After The Signing up",
        MAX(s.session_begins) AS "The Last Login",
        NOW() - MAX(s.session_begins) AS "The Time Since The Last Visit",
        MAX(s.session_begins) - u.created_at AS "The Activation Time",
        COUNT(DISTINCT s.session_id) AS "Number OF Visits"
    FROM 
        session_summaries AS s
    JOIN 
        users AS u ON u.user_id = s.user_id
    GROUP BY 
        u.user_id
),
recency AS (
    SELECT
        user_id,
        "The Last Login",
        PERCENT_RANK() OVER (ORDER BY "The Time Since The Last Visit" DESC) AS cumulative_distribution
    FROM 
        Activation_hub
    ORDER BY
        cumulative_distribution ASC
),
frequency AS (
    SELECT
        user_id,
        "Number OF Visits",
        PERCENT_RANK() OVER (ORDER BY "Number OF Visits") AS cumulative_distribution
    FROM 
        Activation_hub
    ORDER BY 
        cumulative_distribution DESC
),
Monterey AS (
    SELECT
        user_id,
        COUNT(DISTINCT order_id) AS "Number Of Orders",
        SUM(sale_price) AS "Customer Lifetime Value",
        PERCENT_RANK() OVER (ORDER BY SUM(sale_price)) AS cumulative_distribution
    FROM (
        SELECT 
            user_id,
            order_id,
            sale_price
        FROM 
            Order_items
        WHERE 
            status NOT IN ('Cancelled', 'Returned')
        GROUP BY 
            user_id, order_id, sale_price
    ) AS Sub
    GROUP BY
        user_id
)
SELECT
    recency.user_id,
    recency."The Last Login",
    recency.cumulative_distribution AS recency,
    frequency."Number OF Visits",
    frequency.cumulative_distribution AS frequency,
    Monterey."Customer Lifetime Value",
    Monterey.cumulative_distribution AS monterey
FROM
    recency
JOIN
    frequency ON recency.user_id = frequency.user_id
JOIN
    Monterey ON Monterey.user_id = recency.user_id
WHERE 
    recency.cumulative_distribution >= 0.9 
    AND frequency.cumulative_distribution >= 0.9
    AND Monterey.cumulative_distribution >= 0.9




/* Bounus */
	
activation_stat_for_users As
(
	SELECT	
		MIN("The Activation Time") AS "Minimum Duration",
 		PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY "The Activation Time") AS "1st Quartile",
    	PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY "The Activation Time") AS "Median",
 		PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY "The Activation Time") AS "3rd Quartile",
		PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY "The Activation Time") AS "90th"
    	MAX("The Activation Time") AS "Maximum Duration",
		TO_CHAR(MODE() WITHIN GROUP (ORDER BY "The Activation Time"),'HH24 "hours" MI "minutes" SS "seconds"') AS "The Mode",
		AVG("The Activation Time") AS "The Average Duration",
		Count(DISTINCT case When "Number OF Visits"=1 Then user_id ELSE NULL END) AS "One Visit",
		Count(DISTINCT case When "Number OF Visits"=2 Then user_id ELSE NULL END) AS "Two Visits",
		Count(DISTINCT case When "Number OF Visits"=3 Then user_id ELSE NULL END) AS "Three Visits",
		Count(DISTINCT case When "Number OF Visits">=4 Then user_id ELSE NULL END) AS "Multiple Visits"
	FROM
		Activation_hub

),
monthly_active_users AS
(SELECT 
	DISTINCT a.user_id
from 
	session_summaries as a 
JOIN
	session_summaries as b
On 
	a.user_id=b.user_id
AND 
	b.session_begins BETWEEN a.session_begins AND  a.session_begins + INTERVAL '30 days'
AND 
	a.session_id <> b.session_id
)

