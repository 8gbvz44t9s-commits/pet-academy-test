-- 派特皇家學院 V2.1：日期修改（單一交易，失敗自動回滾）
-- 先在 Supabase SQL Editor 執行，再部署 V2.1 網頁。
CREATE OR REPLACE FUNCTION public.change_booking_dates(
  p_booking_id uuid,
  p_start_date date,
  p_end_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_booking public.bookings%ROWTYPE;
  v_date date;
  v_template public.daily_activities%ROWTYPE;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '請先登入';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND active = true AND role IN ('admin','staff')
  ) THEN
    RAISE EXCEPTION '沒有修改預約的權限';
  END IF;
  SELECT * INTO v_booking FROM public.bookings
  WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR v_booking.status <> 'confirmed' THEN
    RAISE EXCEPTION '預約不存在或已取消';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL THEN
    RAISE EXCEPTION '請填寫完整日期';
  END IF;
  IF v_booking.booking_type = 'boarding' THEN
    IF p_end_date <= p_start_date OR p_end_date > p_start_date + 119 THEN
      RAISE EXCEPTION '住宿退宿日必須晚於入住日，且最多119晚';
    END IF;
  ELSIF v_booking.booking_type = 'daycare' THEN
    IF p_end_date <> p_start_date THEN
      RAISE EXCEPTION '安親開始與結束日期必須相同';
    END IF;
  ELSE
    RAISE EXCEPTION '未知預約類型';
  END IF;
  IF v_booking.start_date = p_start_date AND v_booking.end_date = p_end_date THEN
    RETURN;
  END IF;

  -- 保留原日期上已安排的課程；新增日期沿用學院等非游泳設定。
  -- 游泳不自動延伸至新日期，避免超出泳池名額。
  SELECT * INTO v_template FROM public.daily_activities
  WHERE booking_id = p_booking_id ORDER BY activity_date LIMIT 1;

  -- bookings 上既有房型容量、每日預約防重觸發器照常執行。
  UPDATE public.bookings
  SET start_date = p_start_date, end_date = p_end_date
  WHERE id = p_booking_id AND status = 'confirmed';

  -- 只移除已不在預約範圍的活動，保留重疊日期的原始設定。
  DELETE FROM public.daily_activities
  WHERE booking_id = p_booking_id
    AND (activity_date < p_start_date
      OR activity_date >= CASE WHEN v_booking.booking_type = 'boarding'
        THEN p_end_date ELSE p_start_date + 1 END);

  FOR v_date IN
    SELECT generate_series(
      p_start_date,
      CASE WHEN v_booking.booking_type = 'boarding'
        THEN p_end_date - 1 ELSE p_start_date END,
      interval '1 day'
    )::date
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.daily_activities
      WHERE booking_id = p_booking_id AND dog_id = v_booking.dog_id AND activity_date = v_date
    ) THEN
      INSERT INTO public.daily_activities
        (booking_id,dog_id,activity_date,academy,swimming,elective,after_swim_service,old_ticket_course)
      VALUES
        (p_booking_id,v_booking.dog_id,v_date,v_template.academy,false,
         v_template.elective,NULL,v_template.old_ticket_course);
    END IF;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.change_booking_dates(uuid,date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.change_booking_dates(uuid,date,date) TO authenticated;
