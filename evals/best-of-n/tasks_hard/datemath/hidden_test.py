from datetime import date as D
from datemath import add_months as am, add_business_days as ab, months_between as mb


def test_add_months_clamp():
    assert am(D(2024, 1, 31), 1) == D(2024, 2, 29) and am(D(2023, 1, 31), 1) == D(2023, 2, 28)
    assert am(D(2024, 1, 15), -1) == D(2023, 12, 15) and am(D(2024, 3, 30), -1) == D(2024, 2, 29)
    assert am(D(2024, 1, 15), 25) == D(2026, 2, 15) and am(D(2024, 5, 10), -17) == D(2022, 12, 10)


def test_add_months_end_of_month():
    assert am(D(2024, 2, 29), 1) == D(2024, 3, 31) and am(D(2023, 4, 30), 1) == D(2023, 5, 31)
    assert am(D(2024, 2, 29), 12) == D(2025, 2, 28) and am(D(2023, 2, 28), 12) == D(2024, 2, 29)
    assert am(D(2023, 2, 28), -1) == D(2023, 1, 31) and am(D(2024, 2, 28), 1) == D(2024, 3, 28)


def test_business_days():
    assert ab(D(2024, 6, 7), 1) == D(2024, 6, 10)  # Fri -> Mon
    assert ab(D(2024, 6, 10), -1) == D(2024, 6, 7) and ab(D(2024, 6, 10), 5) == D(2024, 6, 17)
    assert ab(D(2024, 6, 8), 1) == D(2024, 6, 10) and ab(D(2024, 6, 8), -1) == D(2024, 6, 7)  # Saturday
    assert ab(D(2024, 6, 8), 0) == D(2024, 6, 10) and ab(D(2024, 6, 5), 0) == D(2024, 6, 5)
    assert ab(D(2024, 6, 8), 2) == D(2024, 6, 11)


def test_business_days_holidays():
    h = [D(2024, 12, 25), D(2024, 12, 26)]
    assert ab(D(2024, 12, 24), 1, h) == D(2024, 12, 27) and ab(D(2024, 12, 27), -1, h) == D(2024, 12, 24)
    assert ab(D(2024, 12, 25), 0, h) == D(2024, 12, 27) and ab(D(2024, 12, 20), 5, h) == D(2024, 12, 31)


def test_months_between():
    assert mb(D(2024, 1, 31), D(2024, 2, 29)) == 1 and mb(D(2023, 1, 30), D(2023, 2, 28)) == 1
    assert mb(D(2023, 1, 30), D(2023, 2, 27)) == 0 and mb(D(2024, 1, 15), D(2024, 1, 15)) == 0
    assert mb(D(2024, 1, 15), D(2025, 1, 14)) == 11 and mb(D(2024, 1, 15), D(2025, 1, 15)) == 12
    assert mb(D(2025, 1, 15), D(2024, 1, 15)) == -12 and mb(D(2024, 2, 29), D(2024, 3, 30)) == 0
    assert mb(D(2024, 2, 29), D(2024, 3, 31)) == 1
