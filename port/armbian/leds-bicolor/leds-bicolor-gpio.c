// SPDX-License-Identifier: GPL-2.0
/*
 * Bi-colour LED on a single GPIO, as on the Rombica SmartBox A2 (GPIODV_24): the pin driven high
 * lights one colour (blue), driven low the other (red), and as an input (high impedance) the LED
 * is off. Each colour is an LED class device with the usual triggers; while both are on, the
 * "low" colour is shown. Same behaviour as the sysled driver of the port's Android kernel
 * (port/kernel/patches/0006).
 *
 *	led-bicolor {
 *		compatible = "rombica,bicolor-gpio-led";
 *		gpios = <&gpio GPIODV_24 GPIO_ACTIVE_HIGH>;
 *		high { label = "rombica:blue"; linux,default-trigger = "default-on"; };
 *		low { label = "rombica:red"; };
 *	};
 */
#include <linux/gpio/consumer.h>
#include <linux/leds.h>
#include <linux/module.h>
#include <linux/mod_devicetable.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/property.h>

struct bicolor_led {
	struct gpio_desc *gpio;
	struct mutex lock;		/* the pin follows both colours */
	struct led_classdev high, low;
	bool high_on, low_on;
};

static int bicolor_apply(struct bicolor_led *b)
{
	if (b->low_on)
		return gpiod_direction_output(b->gpio, 0);
	if (b->high_on)
		return gpiod_direction_output(b->gpio, 1);
	return gpiod_direction_input(b->gpio);
}

static int bicolor_set(struct led_classdev *cdev, enum led_brightness value)
{
	struct bicolor_led *b = dev_get_drvdata(cdev->dev->parent);
	int ret;

	mutex_lock(&b->lock);
	if (cdev == &b->low)
		b->low_on = value != LED_OFF;
	else
		b->high_on = value != LED_OFF;
	ret = bicolor_apply(b);
	mutex_unlock(&b->lock);
	return ret;
}

static int bicolor_register(struct device *dev, struct led_classdev *cdev, const char *node)
{
	struct led_init_data init = { };
	struct fwnode_handle *child;
	int ret;

	child = device_get_named_child_node(dev, node);
	if (!child)
		return dev_err_probe(dev, -EINVAL, "no \"%s\" node\n", node);
	init.fwnode = child;
	cdev->max_brightness = 1;
	cdev->brightness_set_blocking = bicolor_set;	/* GPIO direction may sleep */
	ret = devm_led_classdev_register_ext(dev, cdev, &init);
	fwnode_handle_put(child);
	return ret;
}

static int bicolor_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct bicolor_led *b;
	int ret;

	b = devm_kzalloc(dev, sizeof(*b), GFP_KERNEL);
	if (!b)
		return -ENOMEM;
	mutex_init(&b->lock);
	b->gpio = devm_gpiod_get(dev, NULL, GPIOD_IN);		/* off until a colour is on */
	if (IS_ERR(b->gpio))
		return dev_err_probe(dev, PTR_ERR(b->gpio), "no gpio\n");
	platform_set_drvdata(pdev, b);
	ret = bicolor_register(dev, &b->high, "high");
	if (ret)
		return ret;
	return bicolor_register(dev, &b->low, "low");
}

static const struct of_device_id bicolor_of_match[] = {
	{ .compatible = "rombica,bicolor-gpio-led" },
	{ }
};
MODULE_DEVICE_TABLE(of, bicolor_of_match);

static struct platform_driver bicolor_driver = {
	.probe = bicolor_probe,
	.driver = {
		.name = "leds-bicolor-gpio",
		.of_match_table = bicolor_of_match,
	},
};
module_platform_driver(bicolor_driver);

MODULE_DESCRIPTION("Bi-colour LED on one GPIO (high / low / off)");
MODULE_AUTHOR("Dolbaras <dolbaras@localhost>");
MODULE_LICENSE("GPL");
